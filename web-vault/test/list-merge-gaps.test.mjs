// Recover a List's merge, the gaps from Hal's review of Lazarus 0.7 (RESEARCH/NV_MERGE_VS_HAL_REVIEW.md, Logen
// 2026-11-03 "fill the gaps"). These are the reference fixtures the iPhone/Mac and Android merges mirror:
//  1 swap clobber            2 bulk cleanup           3 small list / relay list   4 gap between versions
//  5 10002 marker            6 unpicked in-between    7 re-read changes current   8 step drain 40→20→10→5
//  9 the wipe flag on a drain step                    10 a removal just before a wipe goes with the wipe
//  11 NIP-44 always, and the 64 KB cap                12 the mute line counts every type
// Throwaway keys; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import { openVersion, buildMerge, mergeSummary, mergedTags, wasWipe, VAULT_KEEP } from "../src/net/list-version-merge.js"
import { saveMerged } from "../src/net/list-merge-save.js"
import { ListNotSaved } from "../src/net/list-edit.js"
import { remuteLine, leftOutLines, entryNote } from "../src/net/list-version-labels.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const KEY = nip44.v2.utils.getConversationKey(SK, ME)
const P = n => n.toString(16).padStart(64, "0")
const range = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i)
const ev = (kind, tags, created_at, content = "", from = ["vault"]) => ({ ...finalizeEvent({ kind, created_at, tags, content }, SK), from })
const follows = (ns, at, from) => ev(3, ns.map(n => ["p", P(n)]), at, "", from)
const open = c => nip44.v2.decrypt(c, KEY)
const opened = evs => Promise.all(evs.map(e => openVersion(e, open)))
const rowOf = (rows, n) => rows.find(r => r.tag[1] === P(n))
const newestFirst = vs => [...vs].sort((a, b) => b.ev.created_at - a.ev.created_at)

test("1 swap clobber: a stale list of the same size that swapped the entries out is a wipe", async () => {
  const [v1, v2] = await opened([follows(range(1, 20), 10), follows(range(101, 120), 20)]) // same 20, all different
  const rows = buildMerge({ current: v2, picked: [v1], all: [v2, v1] })
  for (const n of range(1, 20)) {
    assert.equal(rowOf(rows, n).status, "lost", `P(${n}) went in the swap`)
    assert.equal(rowOf(rows, n).ticked, true)
  }
})

test("2 bulk cleanup: 5 of 20 unfollowed on purpose stays out; more than half reads as a wipe", async () => {
  const [a1, a2] = await opened([follows(range(1, 20), 10), follows(range(6, 20), 20)])
  const out = buildMerge({ current: a2, picked: [a1], all: [a2, a1] })
  for (const n of range(1, 5)) assert.deepEqual([rowOf(out, n).status, rowOf(out, n).ticked], ["removed", false])
  // 11 of 20 is more than half: by numbers it can't be told from a wipe, so it comes back, ticked, to untick in Review.
  const [b1, b2] = await opened([follows(range(1, 20), 10), follows(range(12, 20), 20)])
  const back = buildMerge({ current: b2, picked: [b1], all: [b2, b1] })
  assert.equal(rowOf(back, 1).status, "lost")
  // Exactly half kept is still an edit.
  const [c1, c2] = await opened([follows(range(1, 20), 10), follows(range(11, 20), 20)])
  assert.equal(rowOf(buildMerge({ current: c2, picked: [c1], all: [c2, c1] }), 1).status, "removed")
})

test("3 small list and relay lists: everything an old version had goes back ticked", async () => {
  const [s1, s2] = await opened([follows([1, 2, 3, 4, 5], 10), follows([1, 2, 3, 4], 20)])
  const small = buildMerge({ current: s2, picked: [s1], all: [s2, s1] })
  assert.deepEqual([rowOf(small, 5).status, rowOf(small, 5).ticked], ["back", true])
  // A DM relay list of 12, one dropped in an edit: still offered back (relay lists never judge "you removed it").
  const urls = range(1, 12).map(n => ["relay", `wss://r${n}.example`])
  const [r1, r2] = await opened([ev(10050, urls, 10), ev(10050, urls.slice(1), 20)])
  const relays = buildMerge({ current: r2, picked: [r1], all: [r2, r1] })
  const r = relays.find(x => x.tag[1] === "wss://r1.example")
  assert.deepEqual([r.status, r.ticked, r.at], ["back", true, 20])
  // Ticked, but Review still says when it went (Tron note 1 on #1595): a dropped DM relay, a dropped short-list entry.
  const date = t => `t${t}`
  assert.equal(entryNote(r, date, { box: true }), "You removed this t20")
  assert.equal(entryNote(r, date), "Dropped t20, can't tell by whom")
  assert.deepEqual([rowOf(small, 5).at, entryNote(rowOf(small, 5), date, { box: true })], [20, "You removed this t20"])
  // No later version: nothing to date, no line.
  const [n1] = await opened([follows([1, 2], 10)])
  const none = buildMerge({ current: null, picked: [n1], all: [n1] })
  assert.deepEqual([rowOf(none, 1).status, rowOf(none, 1).at, entryNote(rowOf(none, 1), date, { box: true })], ["back", 0, ""])
  // A short list emptied in one step is a wipe, not "you removed": lost, still ticked.
  const [e1, e2] = await opened([follows([1, 2, 3], 10), follows([], 20)])
  const emptied = rowOf(buildMerge({ current: e2, picked: [e1], all: [e2, e1] }), 1)
  assert.deepEqual([emptied.status, emptied.ticked, emptied.at, entryNote(emptied, date, { box: true })], ["lost", true, 20, "Lost t20"])
  // Blocked relays across a gap too: relay lists don't wait on the gap rule.
  const [b1, b2, b3] = await opened([ev(10006, [["relay", "wss://x.example"]], 10, "", ["relays"]), ev(10006, [["relay", "wss://y.example"]], 20, "", ["relays"]), ev(10006, [["relay", "wss://y.example"]], 30)])
  assert.equal(buildMerge({ current: b3, picked: [b1], all: [b3, b2, b1] }).find(x => x.tag[1] === "wss://x.example").status, "back")
})

test("4 gap: a step the vault didn't keep both sides of can't be judged, so it stays out", async () => {
  // v2 was found only on a relay: the vault never had it, so versions between v1 and v2 may be missing.
  const [v1, v2, v3] = await opened([follows(range(1, 20), 10), follows(range(2, 20), 20, ["relays"]), follows(range(2, 20), 30)])
  const rows = buildMerge({ current: v3, picked: [v1], all: [v3, v2, v1] })
  assert.deepEqual([rowOf(rows, 1).status, rowOf(rows, 1).ticked, rowOf(rows, 1).at], ["unsure", false, 20])
  const sum = mergeSummary(3, rows)
  assert.equal(sum.unsure, 1)
  assert.match(leftOutLines(sum).join(" "), /1 stays out because the versions in between weren't all kept/)
  // The same versions all from the vault: an ordinary edit, judged.
  const [w1, w2, w3] = await opened([follows(range(1, 20), 10), follows(range(2, 20), 20), follows(range(2, 20), 30)])
  assert.equal(rowOf(buildMerge({ current: w3, picked: [w1], all: [w3, w2, w1] }), 1).status, "removed")
  // Past the vault's newest VAULT_KEEP its versions have holes (only wipes' pins are kept): unsure there too.
  const evs = [follows(range(1, 20), 1)]
  for (let i = 0; i <= VAULT_KEEP; i++) evs.push(follows(range(2, 20).concat([1000 + i]), 10 + i))
  const vs = await opened(evs)
  const cur = vs[vs.length - 1]
  const old = buildMerge({ current: cur, picked: [vs[0], vs[VAULT_KEEP]], all: vs })
  assert.equal(rowOf(old, 1).status, "unsure", "dropped between two versions the vault has trimmed between")
  assert.equal(rowOf(old, 1000 + VAULT_KEEP - 1).status, "removed", "dropped inside the newest 20: judged")
})

test("5 kind 10002: the list now's read/write marker wins; an entry not in it keeps the newest picked one's", async () => {
  const [old, mid, cur] = await opened([
    ev(10002, [["r", "wss://a.example"], ["r", "wss://b.example", "write"]], 10),
    ev(10002, [["r", "wss://a.example/", "write"], ["r", "wss://b.example", "read"]], 20),
    ev(10002, [["r", "wss://A.example", "read"]], 30),
  ])
  const rows = buildMerge({ current: cur, picked: [old, mid], all: [cur, mid, old] })
  assert.equal(rows.length, 2, "a.example spelled three ways is one relay")
  assert.deepEqual(rows.find(r => r.key.includes("a.example")).tag, ["r", "wss://A.example", "read"], "not widened to read and write")
  assert.deepEqual(rows.find(r => r.key.includes("b.example")).tag, ["r", "wss://b.example", "read"], "the newest picked form")
  assert.equal(rows.find(r => r.key.includes("b.example")).ticked, true, "a relay list: back ticked")
  // Still not saved from Recover a List: only Settings › Relays sends a 10002 (Logen 2026-10-31).
  const ctx = { session: { pubkey: ME }, signer: {}, vault: {}, account: { relays: { write: [] } } }
  await assert.rejects(saveMerged(ctx, 10002, { base: cur.ev, tags: [["r", "wss://b.example"]] }), /can't be merged/)
})

test("6 unpicked in-between: the newest of all versions holding it decides, picked or not", async () => {
  // P(1) is in v1 (picked) and v2 (not picked); v3 swapped the list out. Judging v1 -> v2 would find nothing, and
  // judging from the picked versions alone would skip the wipe.
  const [v1, v2, v3, cur] = await opened([
    follows(range(1, 20), 10), follows(range(1, 25), 20), follows(range(101, 125), 30), follows(range(101, 126), 40),
  ])
  const rows = buildMerge({ current: cur, picked: [v1], all: [cur, v3, v2, v1] })
  assert.deepEqual([rowOf(rows, 1).status, rowOf(rows, 1).at], ["lost", 30])
  assert.ok(!rows.some(r => r.tag[1] === P(21)), "only the picked versions' entries are offered")
})

test("7 re-read changes current: Save refuses, and the rebuilt merge judges again with the new list", async () => {
  const [v1, cur1] = await opened([follows(range(1, 20), 10), follows(range(1, 20).concat([50]), 20)])
  const before = buildMerge({ current: cur1, picked: [v1], all: [cur1, v1] })
  assert.equal(rowOf(before, 50).status, "current")
  // Another app saved the list meanwhile, dropping P(50) in an ordinary edit.
  const cur2ev = follows(range(1, 20), 30)
  const ctx = { session: { pubkey: ME }, signer: {}, vault: {}, account: { relays: { write: [] } } }
  await assert.rejects(saveMerged(ctx, 3, { base: cur1.ev, tags: mergedTags(before, cur1).tags, latest: async () => ({ event: cur2ev, checked: true }) }),
    e => e instanceof ListNotSaved && e.checked, "the page reloads on this one (RecoverListPage onStale)")
  const [cur2] = await opened([cur2ev])
  const after = buildMerge({ current: cur2, picked: [v1, cur1], all: [cur2, cur1, v1] })
  assert.deepEqual([rowOf(after, 50).status, rowOf(after, 50).ticked], ["removed", false], "not 'current' any more: judged as the edit it was")
})

test("8 step drain 40→20→10→5: every step's losses are a wipe, though no single step lost over half", async () => {
  const vs = await opened([follows(range(1, 40), 10), follows(range(1, 20), 20), follows(range(1, 10), 30), follows(range(1, 5), 40)])
  const cur = vs[3]
  const rows = buildMerge({ current: cur, picked: [vs[0]], all: vs })
  for (const n of [30, 15, 8]) assert.deepEqual([rowOf(rows, n).status, rowOf(rows, n).ticked], ["lost", true], `P(${n})`)
  assert.equal(mergeSummary(3, rows).added, 35)
})

test("9 the 'wiped your list' flag sees a drain step, not only a halving next to it", async () => {
  const drain = newestFirst(await opened([follows(range(1, 40), 10), follows(range(1, 20), 20), follows(range(1, 10), 30)]))
  assert.deepEqual(drain.map((_, j) => wasWipe(drain, j)), [true, false, false], "10 wiped 40 (two steps back); 20 kept half")
  const after = newestFirst(await opened([follows(range(1, 40), 10), follows(range(1, 10), 20), follows(range(1, 9), 30)]))
  assert.deepEqual(after.map((_, j) => wasWipe(after, j)), [false, true, false], "9 is an edit after the wipe, not a second one")
  const swap = newestFirst(await opened([follows(range(1, 20), 10), follows(range(101, 120), 20)]))
  assert.equal(wasWipe(swap, 0), true, "a same-size swap")
})

test("10 a removal one step before a wipe goes with the wipe (as the vault pins it), ticked to untick in Review", async () => {
  const vs = await opened([follows(range(1, 21), 10), follows(range(1, 20), 20), follows(range(1, 4).concat(range(30, 35)), 30)])
  const rows = buildMerge({ current: vs[2], picked: [vs[0]], all: vs })
  assert.equal(rowOf(rows, 21).status, "lost")
  // Past LOOKBACK versions the wipe no longer reaches back to it.
  const evs = [follows(range(1, 21), 1), follows(range(1, 20), 2)]
  for (let i = 0; i < 5; i++) evs.push(follows(range(1, 20).concat([500 + i]), 3 + i))
  evs.push(follows([1], 20))
  const far = await opened(evs)
  assert.equal(rowOf(buildMerge({ current: far[far.length - 1], picked: [far[0]], all: far }), 21).status, "removed")
})

test("11 NIP-44 always, also over a NIP-04 list; over 64 KB of private entries is refused before signing", async () => {
  const nip04ct = await nip04.encrypt(SK, ME, JSON.stringify([["p", P(1)]]))
  const base = finalizeEvent({ kind: 10000, created_at: 100, tags: [], content: nip04ct }, SK)
  let signed = 0
  const stored = []
  const ctx = {
    session: { pubkey: ME },
    account: { relays: { write: ["wss://w.example"] } },
    signer: {
      signEvent: async t => { signed++; return finalizeEvent({ ...t }, SK) },
      crypto: { encrypt: async (peer, text) => nip44.v2.encrypt(text, nip44.v2.utils.getConversationKey(SK, peer)) },
    },
    vault: {
      outbox: { event: async e => { stored.push(e); return { ok: true, message: "" } } },
      lists: { query: async () => stored },
    },
  }
  const big = range(1, 1000).map(n => ["p", P(n)]) // 1000 × ~71 bytes
  await assert.rejects(saveMerged(ctx, 10000, { base, baseOpened: true, tags: [], privateTags: big, latest: async () => ({ event: base, checked: true }), publish: urls => urls.map(() => Promise.resolve("")) }), /NIP-44 holds 64 KB/)
  assert.equal(signed, 0)
  const r = await saveMerged(ctx, 10000, { base, baseOpened: true, tags: [], privateTags: [["p", P(1)], ["word", "x"]], latest: async () => ({ event: base, checked: true }), publish: urls => urls.map(() => Promise.resolve("")) })
  assert.ok(!/\?iv=/.test(r.event.content), "not NIP-04")
  assert.deepEqual(JSON.parse(nip44.v2.decrypt(r.event.content, KEY)), [["p", P(1)], ["word", "x"]])
})

test("12 the mute line counts people, words, hashtags and threads", async () => {
  const many = range(200, 209).map(n => ["p", P(n)])
  const [old, cur] = await opened([
    ev(10000, [...many, ["p", P(1)], ["p", P(2)], ["word", "spam"], ["t", "nsfw"], ["e", P(9)]], 10),
    ev(10000, [], 20), // a wipe
  ])
  const sum = mergeSummary(10000, buildMerge({ current: cur, picked: [old], all: [cur, old] }))
  assert.deepEqual(sum.remutes, { people: 12, words: 1, hashtags: 1, threads: 1 })
  assert.equal(remuteLine(sum.remutes), "This mutes again: 12 people, 1 word, 1 hashtag, 1 thread.")
  assert.equal(remuteLine({ people: 1, words: 0, hashtags: 2, threads: 0 }), "This mutes again: 1 person, 2 hashtags.")
  assert.equal(remuteLine({ people: 0, words: 0, hashtags: 0, threads: 0 }), "")
  assert.equal(mergeSummary(3, buildMerge({ current: cur, picked: [old], all: [cur, old] })).remutes.people, 0, "only a mute list mutes")
})

test("13 strict rule 4: any newer version with an unread private part makes it can't tell, unticked", async () => {
  const unreadBlob = nip44.v2.encrypt(JSON.stringify([["p", P(99)]]), nip44.v2.utils.getConversationKey(generateSecretKey(), ME))
  const mutes = n => range(1, n).map(k => ["p", P(k)])
  // The unread one is two steps on, not the next: the next alone would call it "removed".
  const [m1, m2, m3, m4] = await opened([ev(10000, mutes(20), 10), ev(10000, mutes(20).slice(1), 20), ev(10000, mutes(20).slice(1), 30, unreadBlob), ev(10000, mutes(20).slice(1), 40)])
  const rows = buildMerge({ current: m4, picked: [m1], all: [m4, m3, m2, m1] })
  assert.deepEqual([rowOf(rows, 1).status, rowOf(rows, 1).ticked], ["unsure", false])
})

test("14 gap bridged by a wipe: the step to a relay-only version that wiped H is judged a wipe", async () => {
  const [v1, v2, v3] = await opened([follows(range(1, 20), 10), follows([1, 2], 20, ["relays"]), follows([1, 2], 30)])
  const rows = buildMerge({ current: v3, picked: [v1], all: [v3, v2, v1] })
  assert.deepEqual([rowOf(rows, 5).status, rowOf(rows, 5).ticked, rowOf(rows, 5).at], ["lost", true, 20])
})
