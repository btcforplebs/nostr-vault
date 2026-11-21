// Tidy's perf audit 11-20, batch E: follow lists held compact (W8), asked of one profile relay at a time (W6), and the
// web built once per set of lists, a slice at a time (W10). Throwaway keys only; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { FollowList, compactList, interner, pack, unpack } from "../src/net/wot-store.js"
import { askInTurn, buildWeb, buildWebSoon, builtWeb, followLists, LISTS_WAIT_MS, HANDOFF_WAIT_MS } from "../src/net/wot.js"
import { vouchesFrom } from "../src/net/for-you.js"
import { trustedWeb } from "../src/net/notifications.js"

const hex = (c, n = 0) => c.repeat(63) + n.toString(16).slice(-1)
const key = i => i.toString(16).padStart(64, "0")

test("a held list keeps only valid p keys, once each, and still reads as a kind 3's p tags", () => {
  const ev = { id: "x", sig: "y", content: '{"wss://r":{}}', kind: 3, pubkey: hex("1"), created_at: 7,
    tags: [["p", hex("a"), "wss://hint", "pet"], ["p", hex("b")], ["p", hex("a")], ["t", "x"], ["p", "nothex"], ["p", hex("A")], ["p"]] }
  const l = compactList(ev)
  assert.ok(l instanceof FollowList)
  assert.deepEqual(l.ps, [hex("a"), hex("b")])
  assert.deepEqual(l.tags, [["p", hex("a")], ["p", hex("b")]])
  assert.equal(l.kind, 3); assert.equal(l.pubkey, hex("1")); assert.equal(l.created_at, 7)
  assert.equal(l.content, undefined, "the relay's content blob, petnames and hints are not held")
  assert.equal(compactList(l), l)
})

test("the same key on many lists is one string; the store's round trip gives the same lists", () => {
  const intern = interner()
  const a = compactList({ pubkey: hex("1"), created_at: 1, tags: [["p", hex("a")]] }, intern)
  const b = compactList({ pubkey: hex("2"), created_at: 1, tags: [["p", "" + hex("a")]] }, intern)
  assert.ok(Object.is(a.ps[0], b.ps[0]))
  const back = unpack(pack(a), intern)
  assert.deepEqual(back.ps, a.ps)
  assert.equal(back.ps[0], a.ps[0])
  // A row the old store wrote (before this change) reads back the same way: the rows' format is unchanged.
  const oldRow = pack({ kind: 3, pubkey: hex("3"), created_at: 5, tags: [["p", hex("b")], ["p", hex("c")]] })
  assert.deepEqual(unpack(oldRow).tags, [["p", hex("b")], ["p", hex("c")]])
})

test("readers that walk a kind 3's tags give the same answers from held lists", () => {
  const raw = new Map([[hex("1"), { kind: 3, pubkey: hex("1"), created_at: 1, tags: [["p", hex("a")], ["p", hex("b"), "wss://x"]] }],
    [hex("2"), { kind: 3, pubkey: hex("2"), created_at: 1, tags: [["p", hex("a")]] }]])
  const held = new Map([...raw].map(([k, v]) => [k, compactList(v)]))
  const fs = [hex("1"), hex("2")]
  assert.deepEqual([...vouchesFrom(fs, held)].sort(), [...vouchesFrom(fs, raw)].sort())
  assert.deepEqual([...trustedWeb(fs, held)].sort(), [...trustedWeb(fs, raw)].sort())
  const w1 = buildWeb(hex("e"), fs, held), w2 = buildWeb(hex("e"), fs, raw)
  assert.deepEqual([w1.follows, w1.extended, w1.further], [w2.follows, w2.extended, w2.further])
})

test("followLists hands out held lists, and asks the second profile relay only for who the first didn't have", async () => {
  const me = hex("e", 7), f1 = hex("4", 1), f2 = hex("4", 2)
  const asked = []
  const query = async ([url], f) => {
    asked.push([url, f.authors])
    const has = url.includes("purplepag") ? [f1] : [f1, f2]
    return has.filter(pk => f.authors.includes(pk)).map(pk => ({ kind: 3, pubkey: pk, created_at: 3, content: "big", tags: [["p", hex("6"), "wss://hint"]] }))
  }
  const got = await followLists(me, [f1, f2], { query, now: () => 7_000_000 })
  assert.equal(got.size, 2)
  assert.ok(got.get(f1) instanceof FollowList)
  assert.deepEqual(got.get(f2).tags, [["p", hex("6")]])
  assert.deepEqual(asked, [["wss://purplepag.es", [f1, f2]], ["wss://index.hzrd149.com", [f2]]])
})

test("askInTurn: a failed, cut-off or capped answer marks the group cut; the next relay is asked for the rest", async () => {
  const chunk = [hex("5", 1), hex("5", 2)], wanted = new Set(chunk)
  const list = pk => ({ kind: 3, pubkey: pk, created_at: 1, tags: [] })
  let r = await askInTurn(["a", "b"], chunk, wanted, { query: async ([u], f) => u === "a" ? [list(chunk[0])] : [] })
  assert.equal(r.cut, false); assert.equal(r.evs.length, 1)
  r = await askInTurn(["a", "b"], chunk, wanted, { query: async ([u], f) => { if (u === "a") throw new Error("down"); return f.authors.map(list) } })
  assert.equal(r.cut, true); assert.equal(r.evs.length, 2)
  let t = 0
  r = await askInTurn(["a"], chunk, wanted, { query: async () => { t += LISTS_WAIT_MS; return [] }, now: () => t })
  assert.equal(r.cut, true, "timed out")
  const asked = []
  r = await askInTurn(["a", "b"], chunk, wanted, { query: async ([u], f) => { asked.push(u); return f.authors.map(list) } })
  assert.deepEqual(asked, ["a"], "all there: the second relay is never asked")
  // A first relay that stalls hands on after HANDOFF_WAIT_MS; the last relay gets the whole LISTS_WAIT_MS.
  const waits = []
  t = 0
  r = await askInTurn(["a", "b"], chunk, wanted, { query: async ([u], f, o) => { waits.push(o.maxWait); if (u === "a") { t += o.maxWait; return [] } return f.authors.map(list) }, now: () => t })
  assert.deepEqual(waits, [HANDOFF_WAIT_MS, LISTS_WAIT_MS])
  assert.equal(r.cut, true); assert.equal(r.evs.length, 2, "the second relay brought them")
})

test("buildWebSoon gives buildWeb's web a slice at a time, and the same one again while nothing changed", async () => {
  const me = key(999), follows = Array.from({ length: 100 }, (_, i) => key(i + 1))
  const lists = new Map(follows.map((f, i) => [f, compactList({ pubkey: f, created_at: 1, tags: Array.from({ length: 30 }, (_, j) => ["p", key(1000 + ((i * 7 + j) % 60))]) })]))
  let yields = 0
  const w = await buildWebSoon(me, follows, lists, { slice: 10, yieldTo: async () => { yields++ } })
  const sync = buildWeb(me, follows, lists)
  assert.deepEqual([w.follows, w.extended, w.further, [...w.followsMe]], [sync.follows, sync.extended, sync.further, [...sync.followsMe]])
  assert.ok(yields >= 10, `paused between slices (${yields})`)
  assert.equal(builtWeb(me, follows, new Map(lists)), w, "a new Map of the same lists: the kept web")
  let again = 0
  assert.equal(await buildWebSoon(me, follows, new Map(lists), { yieldTo: async () => { again++ } }), w)
  assert.equal(again, 0)
  const changed = new Map(lists).set(follows[0], compactList({ pubkey: follows[0], created_at: 2, tags: [["p", key(5000)]] }))
  assert.equal(builtWeb(me, follows, changed), null, "a list changed: built again")
  assert.notEqual(await buildWebSoon(me, follows, changed, { yieldTo: async () => {} }), w)
})
