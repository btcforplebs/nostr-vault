// Blocks: the kind 10000 mute list, read from Haven's outbox and the network, and what it hides on each screen.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import * as nip44 from "nostr-tools/nip44"
import * as nip04 from "nostr-tools/nip04"
import {
  pTags, isNip04, decrypterFor, privateBlocks, readBlockList, refreshBlockList, loadBlocks, getBlocks, onBlocks,
  isBlockedNote, repostState, visibleNotes, visiblePeople, visibleRows, visibleReplies,
  muteEntries, muteSet, isMutedNote, resetBlocks,
} from "../src/net/blocks.js"
import { groupNotifications } from "../src/net/notifications.js"

const sk = generateSecretKey()
const ME = getPublicKey(sk)
const A = "a".repeat(64), B = "b".repeat(64), C = "c".repeat(64), D = "d".repeat(64)

// A Haven route as far as blocks.js uses it: query by kind/author, and event() keeping the newest replaceable one.
function fakeVault(seed = []) {
  const evs = [...seed]
  const outbox = {
    stored: evs,
    query: async f => evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey)),
    event: async ev => { if (evs.some(e => e.id === ev.id)) return { ok: false, message: "duplicate: have it" }; evs.push(ev); return { ok: true, message: "" } },
  }
  return { outbox }
}
const list = (tags, content = "", created_at = 100) => finalizeEvent({ kind: 10000, created_at, tags, content }, sk)

test("public blocks are the valid p tags, lowercased, once each", () => {
  assert.deepEqual(pTags([["p", A], ["p", A.toUpperCase()], ["p", "short"], ["e", B], ["t", "nsfw"], ["p", C, "wss://x"]]), [A, C])
  assert.deepEqual(pTags(undefined), [])
  assert.deepEqual(pTags([null, "p", ["p"]]), [])
})

test("NIP-04 ciphertext is told apart from NIP-44 by its iv", () => {
  assert.equal(isNip04("abc?iv=def"), true)
  assert.equal(isNip04("AgAAAAAA"), false)
})

test("a private part is decrypted with the matching scheme from the extension", async () => {
  const key = nip44.getConversationKey(sk, ME)
  const c44 = nip44.encrypt(JSON.stringify([["p", B], ["t", "x"]]), key)
  const c04 = nip04.encrypt(sk, ME, JSON.stringify([["p", D]]))
  const calls = []
  const ext = {
    nip44: { decrypt: async (pk, c) => { calls.push(["nip44", pk]); return nip44.decrypt(c, key) } },
    nip04: { decrypt: async (pk, c) => { calls.push(["nip04", pk]); return nip04.decrypt(sk, pk, c) } },
  }
  const opener = await decrypterFor({ method: "nip07", pubkey: ME }, { ext })
  assert.deepEqual((await privateBlocks(list([], c44), opener)).pubkeys, [B])
  assert.deepEqual((await privateBlocks(list([], c04), opener)).pubkeys, [D])
  assert.deepEqual(calls, [["nip44", ME], ["nip04", ME]])
})

test("when the private part can't be read, the note says why and the public part still applies", async () => {
  const bunker = await decrypterFor({ method: "nip46", pubkey: ME })
  assert.match(bunker.reason, /bunker isn't connected/)
  assert.deepEqual(await privateBlocks(list([], "AgAAAA"), bunker), { pubkeys: [], tags: [], note: bunker.reason })
  const no44 = await decrypterFor({ method: "nip07", pubkey: ME }, { ext: { nip04: { decrypt: async () => "[]" } } })
  assert.match((await privateBlocks(list([], "AgAAAA"), no44)).note, /NIP44/)
  const refused = await decrypterFor({ method: "nip07", pubkey: ME }, { ext: { nip44: { decrypt: async () => { throw new Error("user said no") } } } })
  assert.equal((await privateBlocks(list([], "AgAAAA"), refused)).note, "user said no")
  assert.deepEqual(await privateBlocks(list([["p", A]], ""), bunker), { pubkeys: [], tags: [], note: "" }, "no private part, nothing to explain")
})

test("the list is read from Haven's outbox, newest first, and the network's copy is stored there", async () => {
  const old = list([["p", A]], "", 100)
  const vault = fakeVault([old])
  assert.equal((await readBlockList(vault, ME)).id, old.id)
  const fresh = list([["p", A], ["p", B]], "", 200)
  const someoneElse = finalizeEvent({ kind: 10000, created_at: 300, tags: [["p", C]], content: "" }, generateSecretKey())
  const got = await refreshBlockList(vault, ME, ["wss://r"], { query: async () => [fresh, someoneElse, old] })
  assert.equal(got.id, fresh.id)
  assert.ok(vault.outbox.stored.includes(fresh))
  assert.ok(!vault.outbox.stored.includes(someoneElse), "only the user's own list is stored")
})

test("loadBlocks shows Haven's copy, then the newer network one, once per account", async () => {
  const vault = fakeVault([list([["p", A]], "", 100)])
  const fresh = list([["p", A], ["p", B]], "", 200)
  let queries = 0, changes = 0
  const off = onBlocks(() => changes++)
  const ctx = { vault, session: { method: "nip46", pubkey: ME } }
  const opener = { reason: "test" }
  const p = loadBlocks(ctx, ["wss://r"], { opener, query: async () => { queries++; return [fresh] } })
  assert.equal(loadBlocks(ctx, ["wss://r"], { opener }), p, "a second screen shares the first load")
  await p
  off()
  assert.deepEqual([...getBlocks().blocked].sort(), [A, B])
  assert.equal(getBlocks().pubkey, ME)
  assert.equal(queries, 1)
  assert.ok(changes >= 2)
})

test("blocked notes and reposts of them are hidden; others stay", () => {
  const aSk = generateSecretKey(), A = getPublicKey(aSk)
  const blocked = new Set([A])
  const mine = { id: "1", kind: 1, pubkey: C }
  const theirs = { id: "2", kind: 1, pubkey: A }
  const repost = { id: "3", kind: 6, pubkey: C, content: JSON.stringify(finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "hi" }, aSk)) }
  const badRepost = { id: "4", kind: 6, pubkey: C, content: "not json" }
  assert.equal(isBlockedNote(theirs, blocked), true)
  assert.equal(isBlockedNote(repost, blocked), true)
  assert.deepEqual(visibleNotes([mine, theirs, repost, badRepost], blocked).map(e => e.id), ["1", "4"])
  const none = [mine, theirs]
  assert.equal(visibleNotes(none, new Set()), none, "nothing blocked, same array")
})

test("a forged repost can't clear a blocked person: unchecked inner = unknown, and the card checks what it fetched", () => {
  const aSk = generateSecretKey(), A = getPublicKey(aSk)
  const blocked = new Set([A])
  const real = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "blocked person's note" }, aSk)
  const repost = (inner, p) => ({ id: "r", kind: 6, pubkey: C, created_at: 2, content: inner ? JSON.stringify(inner) : "", tags: [["e", real.id], ["p", p]] })
  assert.equal(isBlockedNote(repost(real, C), blocked), true, "a signed inner is the author, whatever the p tag says")
  // Tron's probe: the inner pubkey forged to an unblocked key, and a p tag naming the blocked person.
  assert.equal(isBlockedNote(repost({ ...real, pubkey: C }, A), blocked), true, "a forged inner pubkey is not believed")
  // The p tag can hide a repost but never clear one; what slips through, the card catches.
  const slips = [repost({ ...real, pubkey: C }, C), repost(null, C)]
  for (const ev of slips) assert.equal(isBlockedNote(ev, blocked), false)
  assert.equal(repostState(real, new Set([1]), blocked), "blocked", "the fetched note is the blocked person's: not drawn")
  assert.equal(repostState({ ...real, pubkey: C }, new Set([1]), blocked), "note")
  assert.equal(repostState(undefined, new Set([1]), blocked), "loading")
  assert.equal(repostState(null, new Set([1]), blocked), "missing")
  assert.equal(repostState({ kind: 7, pubkey: C }, new Set([1]), blocked), "missing")
  assert.equal(repostState(real, new Set([1]), new Set()), "note", "nothing blocked")
})

test("search people drop blocked pubkeys", () => {
  assert.deepEqual(visiblePeople([A, B, C], new Set([B])), [A, C])
})

test("notification rows lose blocked people and are regrouped", () => {
  const note = "e".repeat(64)
  const ev = (id, kind, pubkey, at, tags = []) => ({ id, kind, pubkey, created_at: at, content: kind === 7 ? "+" : "hi", tags: [["p", ME], ...tags] })
  const raw = [
    ev("r1", 7, A, 10, [["e", note]]),
    ev("r2", 7, B, 11, [["e", note]]),
    ev("m1", 1, A, 12),
    ev("m2", 1, C, 13),
  ]
  const rows = groupNotifications(raw, ME)
  const shown = visibleRows(rows, new Set([A]), ME)
  assert.deepEqual(shown.map(r => [r.type, r.who]), [["mention", [C]], ["reaction", [B]]])
  assert.equal(visibleRows(rows, new Set(), ME), rows)
})

test("a thread drops blocked replies but keeps their unblocked replies in their place", () => {
  const n = (id, pubkey, children = []) => ({ event: { id, kind: 1, pubkey }, children })
  const tree = [n("1", C, [n("2", A, [n("3", B), n("4", A)])]), n("5", A)]
  const shown = visibleReplies(tree, new Set([A]))
  assert.deepEqual(shown, [n("1", C, [n("3", B)])])
})

// ---- Muted words, hashtags and threads (users' lists from other clients carry them, public and private) ----

const T1 = "1".repeat(64), T2 = "2".repeat(64)

test("mute entries: words and hashtags lowercased, threads only as ids", () => {
  const m = muteEntries([["word", "Crypto Scam"], ["word", "crypto scam"], ["t", "#NSFW"], ["e", T1], ["e", "nope"], ["word", " "], ["p", A]])
  assert.deepEqual(m.words, ["crypto scam"])
  assert.deepEqual([...m.hashtags], ["nsfw"])
  assert.deepEqual([...m.threads], [T1])
})

test("muted words, hashtags and threads hide notes, replies and reposts, with nobody blocked", () => {
  const blocked = muteSet([], [["word", "airdrop"], ["t", "nsfw"], ["e", T1]])
  assert.equal(blocked.size, 0)
  const word = { id: "a1", kind: 1, pubkey: C, tags: [], content: "Free AIRDROP now" }
  const tag = { id: "a2", kind: 1, pubkey: C, tags: [["t", "NSFW"]], content: "x" }
  const inThread = { id: "a3", kind: 1, pubkey: C, tags: [["e", T1, "", "root"], ["e", T2, "", "reply"]], content: "x" }
  const root = { id: T1, kind: 1, pubkey: C, tags: [], content: "x" }
  const fine = { id: "a4", kind: 1, pubkey: C, tags: [["t", "art"]], content: "a drop of rain" }
  assert.deepEqual(visibleNotes([word, tag, inThread, root, fine], blocked).map(e => e.id), ["a4"])
  const sk2 = generateSecretKey()
  const inner = finalizeEvent({ kind: 1, created_at: 1, tags: [], content: "airdrop!" }, sk2)
  assert.equal(isBlockedNote({ id: "r", kind: 6, pubkey: C, tags: [["e", inner.id]], content: JSON.stringify(inner) }, blocked), true)
  assert.equal(isMutedNote(fine, new Set([A])), false, "a plain Set mutes nothing")
  const replies = [{ event: inThread, children: [{ event: fine, children: [] }] }]
  assert.deepEqual(visibleReplies(replies, blocked).map(n => n.event.id), ["a4"])
})

test("notifications drop muted-word mentions and reactions on a muted thread", () => {
  const mk = (kind, tags, content = "") => finalizeEvent({ kind, created_at: 10, tags, content }, generateSecretKey())
  const mention = mk(1, [["p", ME]], "airdrop for you")
  const like = mk(7, [["e", T1], ["p", ME]], "+")
  const ok = mk(1, [["p", ME]], "hello")
  const rows = groupNotifications([mention, like, ok], ME)
  const shown = visibleRows(rows, muteSet([], [["word", "airdrop"], ["e", T1]]), ME).flatMap(r => r.events.map(e => e.id))
  assert.deepEqual(shown, [ok.id])
})

test("a private part's words, hashtags and threads apply too, NIP-44 and NIP-04", async () => {
  const key = nip44.getConversationKey(sk, ME)
  for (const enc of [t => nip44.encrypt(t, key), t => nip04.encrypt(sk, ME, t)]) {
    resetBlocks()
    const content = await enc(JSON.stringify([["p", B], ["word", "Secret"], ["t", "spoilers"], ["e", T2]]))
    const vault = fakeVault([list([["p", A], ["word", "loud"]], content, 100)])
    const signer = { crypto: { decrypt: async (pk, c) => nip44.decrypt(c, key), decrypt04: async (pk, c) => nip04.decrypt(sk, pk, c) } }
    await loadBlocks({ vault, signer, session: { method: "nip46", pubkey: ME } }, [], { query: async () => [] })
    const { blocked, privateNote } = getBlocks()
    assert.equal(privateNote, "")
    assert.deepEqual([...blocked].sort(), [A, B])
    assert.deepEqual(blocked.words.sort(), ["loud", "secret"])
    assert.deepEqual([...blocked.hashtags], ["spoilers"])
    assert.deepEqual([...blocked.threads], [T2])
  }
  resetBlocks()
})

test("the account's own relays, known after sign-in, are asked then; earlier ones aren't asked again", async () => {
  resetBlocks()
  const vault = fakeVault()
  const onOwn = list([["p", C]], "", 300)
  const asked = []
  const query = async r => { asked.push(...r); return r.includes("wss://own") ? [onOwn] : [] }
  const ctx = { vault, session: { method: "nip46", pubkey: ME } }
  await loadBlocks(ctx, ["wss://default"], { opener: { reason: "t" }, query })
  assert.equal(getBlocks().blocked.size, 0)
  await loadBlocks(ctx, ["wss://default", "wss://own"], { opener: { reason: "t" }, query })
  assert.deepEqual(asked, ["wss://default", "wss://own"])
  assert.deepEqual([...getBlocks().blocked], [C])
  resetBlocks()
})

test("a private part that couldn't be opened at sign-in is tried again on the next load", async () => {
  resetBlocks()
  const key = nip44.getConversationKey(sk, ME)
  const vault = fakeVault([list([], nip44.encrypt(JSON.stringify([["p", B]]), key), 100)])
  const ctx = { vault, session: { method: "nip46", pubkey: ME } }
  await loadBlocks(ctx, ["wss://a"], { opener: { decrypt: async () => { throw new Error("signer didn't answer") } }, query: async () => [] })
  assert.match(getBlocks().privateNote, /didn't answer/)
  await loadBlocks(ctx, ["wss://b"], { opener: { decrypt: async c => nip44.decrypt(c, key) }, query: async () => [] })
  assert.equal(getBlocks().privateNote, "")
  assert.deepEqual([...getBlocks().blocked], [B])
  resetBlocks()
})
