import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { naddrEncode } from "nostr-tools/nip19"
import { parseEmojiSet, listedSets, withSet, withoutSet, decodeSetLink, setLink, parseAddress, setFilters, newestByAddress,
  browseFilters, browseList, changeSet, keepSet, fetchSets, SET_CAP, AUTHORS_PER_ASK, EMOJI_SET_KIND } from "../src/net/emoji-sets.js"

// Throwaway keys only.
const sk = generateSecretKey(), pk = getPublicKey(sk)
const other = getPublicKey(generateSecretKey())
const signedSet = (d, emoji, at = 1000, extra = []) => finalizeEvent({ kind: 30030, created_at: at, content: "", tags: [["d", d], ["title", d.toUpperCase()], ...emoji.map(([c, u]) => ["emoji", c, u]), ...extra] }, sk)
const addr = d => `30030:${pk}:${d}`

test("parse a set: first link per shortcode, https only, bad codes skipped", () => {
  const s = parseEmojiSet(signedSet("cats", [["blob", "https://x.example/1.png"], ["blob", "https://x.example/2.png"], ["bad code", "https://x.example/3.png"], ["plain", "http://x.example/4.png"], ["ok-1", "https://x.example/5.png"]]))
  assert.equal(s.address, addr("cats"))
  assert.equal(s.title, "CATS")
  assert.deepEqual(s.emoji, [{ code: "blob", url: "https://x.example/1.png" }, { code: "ok-1", url: "https://x.example/5.png" }])
  assert.equal(parseEmojiSet({ ...signedSet("x", []), kind: 30023 }), null)
})

test("10030: sets listed once, in order, capped; loose emoji are not sets", () => {
  const list = { tags: [["emoji", "loose", "https://x.example/l.png"], ["a", addr("b")], ["a", addr("a")], ["a", addr("b")], ["a", `30023:${pk}:post`], ["p", other]] }
  assert.deepEqual(listedSets(list), [addr("b"), addr("a")])
  const many = { tags: Array.from({ length: SET_CAP + 5 }, (_, i) => ["a", addr(`s${i}`)]) }
  assert.equal(listedSets(many).length, SET_CAP)
})

test("add/remove a set keeps every other tag", () => {
  const tags = [["emoji", "loose", "https://x.example/l.png"], ["a", addr("a")], ["x-client", "other"]]
  assert.deepEqual(withSet(tags, addr("b")), [...tags, ["a", addr("b")]])
  assert.equal(withSet(tags, addr("a")), tags, "already there")
  assert.deepEqual(withoutSet(tags, addr("a")), [["emoji", "loose", "https://x.example/l.png"], ["x-client", "other"]])
  assert.deepEqual(withSet(undefined, addr("a")), [["a", addr("a")]])
})

test("set links: naddr, nostr:naddr, bare address; other kinds refused", () => {
  const n = naddrEncode({ kind: 30030, pubkey: pk, identifier: "cats:2", relays: ["wss://r.example", "ws://insecure.example"] })
  assert.deepEqual(decodeSetLink(n), { address: addr("cats:2"), relays: ["wss://r.example"] })
  assert.deepEqual(decodeSetLink(`nostr:${n}`), { address: addr("cats:2"), relays: ["wss://r.example"] })
  assert.deepEqual(decodeSetLink(` ${addr("x")} `), { address: addr("x"), relays: [] })
  assert.equal(decodeSetLink(naddrEncode({ kind: 30023, pubkey: pk, identifier: "a" })), null)
  assert.equal(decodeSetLink("hello"), null)
  assert.equal(decodeSetLink(setLink({ author: pk, d: "cats" }))?.address, addr("cats"))
  assert.deepEqual(parseAddress(addr("a:b")), { kind: EMOJI_SET_KIND, pubkey: pk, d: "a:b" })
})

test("one filter per author; newest copy per asked address, none from the future", () => {
  assert.deepEqual(setFilters([addr("a"), addr("b"), `30030:${other}:c`, "junk"]),
    [{ kinds: [30030], authors: [pk], "#d": ["a", "b"] }, { kinds: [30030], authors: [other], "#d": ["c"] }])
  const old = signedSet("a", [], 100), fresh = signedSet("a", [], 200), future = signedSet("a", [], 5000), stray = signedSet("z", [], 300)
  const best = newestByAddress([old, fresh, future, stray], [addr("a")], 1000)
  assert.deepEqual([...best.keys()], [addr("a")])
  assert.equal(best.get(addr("a")).id, fresh.id)
})

test("browse: follows split into asks; follows' sets first, blocked and empty sets left out", () => {
  const follows = Array.from({ length: AUTHORS_PER_ASK + 1 }, (_, i) => i.toString(16).padStart(64, "0"))
  const f = browseFilters(follows, 10_000_000)
  assert.equal(f.byFollows.length, 2)
  assert.equal(f.global.since, 10_000_000 - 30 * 86400)
  const mine = signedSet("mine", [["a", "https://x.example/a.png"]], 100)
  const theirs = { ...mine, pubkey: other, created_at: 900, tags: [["d", "t"], ["emoji", "b", "https://x.example/b.png"]] }
  const empty = signedSet("empty", [], 950)
  const blocked = { ...theirs, pubkey: "f".repeat(64), created_at: 990 }
  const out = browseList([theirs, mine, empty, blocked], { follows: new Set([pk]), blocked: new Set(["f".repeat(64)]), at: 2000 })
  assert.deepEqual(out.map(s => s.author), [pk, other])
})

const vault = () => {
  const kept = []
  return { kept, outbox: { query: async () => kept.slice(), event: async e => { kept.push(e); return { ok: true } } } }
}
const ctx = (v = vault()) => ({ session: { pubkey: pk }, account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] }, follows: [] }, vault: v })

test("fetchSets: the vault copy shows when relays lost it; a newer relay copy is kept in the vault", async () => {
  const v = vault()
  const old = signedSet("a", [["x", "https://x.example/x.png"]], 100)
  v.kept.push(old)
  let got = await fetchSets(ctx(v), [addr("a")], { query: async () => [] })
  assert.equal(got.get(addr("a")).event.id, old.id)
  const fresh = signedSet("a", [["y", "https://x.example/y.png"]], 200)
  const forged = { ...signedSet("a", [], 300), content: "tampered" }
  got = await fetchSets(ctx(v), [addr("a")], { query: async () => [fresh, forged] })
  assert.equal(got.get(addr("a")).event.id, fresh.id, "an unverified copy is ignored")
  assert.ok(v.kept.some(e => e.id === fresh.id))
})

test("changeSet: add rewrites 10030 from the shown copy and keeps the set; remove keeps nothing", async () => {
  const set = parseEmojiSet(signedSet("cats", [["a", "https://x.example/a.png"]]))
  const previous = { id: "p", tags: [["emoji", "loose", "https://x.example/l.png"]] }
  const calls = []
  const publish = async (_c, kind, tags, opts) => { calls.push({ kind, tags, opts }); return { event: { id: "new", tags } } }
  const kept = []
  const keep = async (_c, ev) => { kept.push(ev.id); return { sent: 1, of: 1, vault: "" } }
  const added = await changeSet(ctx(), { set, add: true, previous }, { publish, keep })
  assert.equal(calls[0].kind, 10030)
  assert.deepEqual(calls[0].tags, [["emoji", "loose", "https://x.example/l.png"], ["a", set.address]])
  assert.equal(calls[0].opts.previous, previous)
  assert.deepEqual(kept, [set.event.id])
  assert.deepEqual(added.kept, { sent: 1, of: 1, vault: "" })
  const removed = await changeSet(ctx(), { set, add: false, previous: { id: "new", tags: calls[0].tags } }, { publish, keep })
  assert.deepEqual(calls[1].tags, [["emoji", "loose", "https://x.example/l.png"]])
  assert.equal(removed.kept, undefined)
  assert.equal(kept.length, 1)
})

test("keepSet resends the author's own signed event unchanged and refuses a forged one", async () => {
  const ev = signedSet("cats", [["a", "https://x.example/a.png"]])
  const v = vault()
  const sent = []
  const r = await keepSet(ctx(v), { ...ev, extra: "dropped" }, { send: (urls, e) => { sent.push([urls, e]); return urls.map(() => Promise.resolve("ok")) } })
  assert.deepEqual(r, { sent: 1, of: 1, vault: "" })
  assert.deepEqual(sent[0][1], { id: ev.id, pubkey: ev.pubkey, created_at: ev.created_at, kind: ev.kind, tags: ev.tags, content: ev.content, sig: ev.sig })
  assert.equal(v.kept[0].id, ev.id)
  await assert.rejects(keepSet(ctx(), { ...ev, content: "x" }, { send: () => [] }))
})
