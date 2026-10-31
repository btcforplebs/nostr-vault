// Coming back to the Feed, or reloading it, asks the relays only for what changed: the follows' contact lists are kept
// in this browser (wot-store.js) and read back without asking, a sync newer than FRESH_MS isn't run again
// (feed-synced.js), and thread roots are asked for once per page load (FeedRows rootFetcher).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { followLists, LISTS_WAIT_MS, REFRESH_MS } from "../src/net/wot.js"
import { pack, unpack, wotStore } from "../src/net/wot-store.js"
import { FRESH_MS, followsKey, markSynced, syncedRecently } from "../src/net/feed-synced.js"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { forgetRoots, rootFetcher, ROOT_RETRY_MS } = await import("../src/components/FeedRows.jsx")

const hex = (c, i = 0) => (c.repeat(63) + i.toString(16)).slice(-64)
const RETRY_MS_PLUS = 61_000 // past wot.js RETRY_MS, inside REFRESH_MS
const list = (pubkey, follows, created_at = 1) => ({ kind: 3, pubkey, created_at, tags: follows.map(p => ["p", p]) })

// A store as wot-store.js gives it, in memory: what was saved comes back packed and unpacked, as from IndexedDB.
function memStore(kept = [], checkedAt = 0) {
  const rows = new Map(kept.map(ev => [ev.pubkey, pack(ev)]))
  const s = { checkedAt, saves: 0 }
  s.load = async () => ({
    lists: new Map([...rows].filter(([, r]) => r.ps).map(([pk, r]) => [pk, unpack(r)])),
    misses: new Map([...rows].filter(([, r]) => !r.ps).map(([pk, r]) => [pk, r.missed])),
    checkedAt: s.checkedAt,
  })
  s.save = async (evs, at, misses = [], missedAt = at) => {
    s.saves++
    for (const ev of evs) rows.set(ev.pubkey, pack(ev))
    for (const pk of misses) rows.set(pk, { pubkey: pk, missed: missedAt })
    if (at != null) s.checkedAt = at
  }
  s.rows = rows
  return s
}

test("a kept list is only who it follows, 32 bytes each, and reads back as the same p tags", () => {
  const ev = { ...list(hex("1"), [hex("a"), hex("b"), hex("a")], 7), tags: [["p", hex("a"), "wss://hint", "pet"], ["p", hex("b")], ["p", hex("a")], ["t", "x"], ["p", "nothex"]] }
  const row = pack(ev)
  assert.equal(row.ps.length, 64, "two people, once each")
  assert.deepEqual(unpack(row), { kind: 3, pubkey: hex("1"), created_at: 7, tags: [["p", hex("a")], ["p", hex("b")]] })
})

test("the next page load reads the follows' lists from this browser and asks the relays for none of them", async () => {
  const me = hex("e", 1), f1 = hex("1", 21), f2 = hex("1", 22)
  const store = memStore()
  const first = await followLists(me, [f1, f2], { store, query: async (r, f) => f.authors.map(pk => list(pk, [hex("6")])) })
  assert.equal(first.size, 2)
  assert.equal(store.rows.size, 2, "both kept")
  assert.ok(store.checkedAt > 0)
  // A new page load: a fresh session cache (another `me` resets it), the same store.
  await followLists(hex("e", 9), [], { store: memStore(), query: async () => [] })
  const asks = []
  const again = await followLists(me, [f1, f2], { store, query: async (r, f) => { asks.push(f); return [] } })
  assert.deepEqual(asks, [], "kept lists are not asked for again") // (a throw in query is swallowed: count the asks)
  assert.deepEqual(again.get(f2).tags, [["p", hex("6")]])
})

test("a new follow's list is asked for on its own, and kept with the rest", async () => {
  const me = hex("e", 2), f1 = hex("1", 31), f3 = hex("1", 33)
  const store = memStore([list(f1, [hex("6")])], Math.floor(Date.now() / 1000))
  const asked = []
  const got = await followLists(me, [f1, f3], { store, query: async (r, f) => { asked.push(f.authors); return [list(f3, [hex("7")])] } })
  assert.deepEqual(asked, [[f3]])
  assert.equal(got.size, 2)
  assert.ok(store.rows.has(f3))
})

test("lists already kept are checked for newer ones `since` the last check, after REFRESH_MS, behind the caller", async () => {
  const me = hex("e", 3), f1 = hex("1", 41)
  const checked = 1_000_000
  const store = memStore([list(f1, [hex("6")], 10)], checked)
  const asked = []
  let answered
  const done = new Promise(r => { answered = r })
  const now = () => (checked * 1000) + REFRESH_MS + 1
  const got = await followLists(me, [f1], { store, now, reachable: async () => {}, query: async (r, f) => { asked.push(f); await new Promise(r => setTimeout(r, 5)); setTimeout(answered); return [list(f1, [hex("8")], 20)] } })
  assert.deepEqual(got.get(f1).tags, [["p", hex("6")]], "the kept list is handed out at once")
  await done; await new Promise(r => setTimeout(r, 0))
  assert.equal(asked.length, 1)
  assert.equal(asked[0].since, checked - 600)
  assert.deepEqual(asked[0].authors, [f1])
  assert.equal(store.checkedAt, Math.floor(now() / 1000), "the check time moves on")
  assert.deepEqual(unpack(store.rows.get(f1)).tags, [["p", hex("8")]], "the newer list is kept")
  const later = []
  assert.deepEqual((await followLists(me, [f1], { store, now, query: async (r, f) => { later.push(f); return [] } })).get(f1).tags, [["p", hex("8")]])
  assert.deepEqual(later, [], "checked once per load")
})

test("a follow whose list the relay didn't have is kept as missing, and not asked for again until REFRESH_MS", async () => {
  const me = hex("e", 4), f1 = hex("2", 1), f2 = hex("2", 2)
  const store = memStore()
  const asked = []
  const query = async (r, f) => { asked.push(f.authors); return f.authors.includes(f1) ? [list(f1, [hex("6")])] : [] }
  let clock = 5_000_000_000
  await followLists(me, [f1, f2], { store, query, now: () => clock })
  assert.deepEqual(store.rows.get(f2), { pubkey: f2, missed: clock / 1000 }, "kept as missing, with when")
  // The next load: f2 is not asked for, f1's list is kept.
  await followLists(hex("e", 9), [], { store: memStore(), query: async () => [] })
  clock += RETRY_MS_PLUS
  const got = await followLists(me, [f1, f2], { store, query, now: () => clock })
  assert.equal(got.size, 1)
  assert.deepEqual(asked, [[f1, f2]], "nothing asked on the next load")
  // Try again (retryMs 0) asks at once, and after REFRESH_MS it is asked again on its own.
  await followLists(me, [f1, f2], { store, query, retryMs: 0, now: () => clock })
  assert.deepEqual(asked.at(-1), [f2])
  await followLists(hex("e", 9), [], { store: memStore(), query: async () => [] })
  clock += REFRESH_MS
  const later = []
  await followLists(me, [f1, f2], { store, reachable: async () => {}, query: async (r, f) => { later.push(f.authors); return f.since ? [] : [list(f2, [hex("7")])] }, now: () => clock })
  assert.deepEqual(later.map(a => a.join()).sort(), [f1, f2].sort(), "after REFRESH_MS: f1's kept list `since` the last check, f2 in full")
  assert.ok(store.rows.get(f2).ps, "its list, once it comes, replaces the miss")
  // A failed ask, or an empty answer (what a timeout gives), is not a miss: it is asked again after RETRY_MS.
  const s2 = memStore()
  await followLists(hex("e", 5), [hex("3", 1)], { store: s2, query: async () => { throw new Error("down") } })
  await followLists(hex("e", 6), [hex("3", 2)], { store: s2, query: async () => [] })
  assert.equal(s2.rows.size, 0)
})

test("a check that can't reach the relay, or is cut off, doesn't move the check time on; nor does a cut-off or capped answer make misses", async () => {
  const f1 = hex("1", 51), checked = 1_000_000
  const late = (checked * 1000) + REFRESH_MS + 1
  // Unreachable: nothing asked, the old check time stays, so the next load asks from there again.
  const s1 = memStore([list(f1, [hex("6")], 10)], checked)
  const asked = []
  await followLists(hex("e", 11), [f1], { store: s1, now: () => late, reachable: async () => { throw new Error("down") }, query: async (r, f) => { asked.push(f); return [] } })
  await new Promise(r => setTimeout(r, 5))
  assert.deepEqual(asked.filter(f => f.since), [])
  assert.equal(s1.checkedAt, checked)
  // Reached, but the answer took the whole wait: not a check either.
  const s2 = memStore([list(f1, [hex("6")], 10)], checked)
  let clock = late
  await followLists(hex("e", 12), [f1], { store: s2, now: () => clock, reachable: async () => {}, query: async () => { clock += 8000; return [] } })
  await new Promise(r => setTimeout(r, 5))
  assert.equal(s2.checkedAt, checked)
  // A group's answer cut off at LISTS_WAIT_MS, or as long as its limit (a relay's cap), makes no misses.
  const f2 = hex("2", 51), f3 = hex("2", 52)
  const s3 = memStore()
  let t3 = 5_000_000_000
  await followLists(hex("e", 13), [f2, f3], { store: s3, now: () => t3, query: async () => { t3 += LISTS_WAIT_MS; return [list(f2, [hex("6")])] } })
  assert.equal(s3.rows.get(f3), undefined, "cut off: f3 not kept as missing")
  const s4 = memStore()
  await followLists(hex("e", 14), [f2, f3], { store: s4, query: async () => [list(f2, [hex("6")], 1), list(f2, [hex("6")], 2)] })
  assert.equal(s4.rows.get(f3), undefined, "two events for a limit of two: maybe capped, f3 not kept as missing")
})

test("a kept-lists read that never answers counts as nothing kept, so the web still loads", async () => {
  const f1 = hex("1", 61)
  const hung = { load: () => new Promise(() => {}), save: async () => {} }
  const got = await followLists(hex("e", 15), [f1], { store: hung, loadMs: 10, query: async (r, f) => f.authors.map(pk => list(pk, [hex("6")])) })
  assert.equal(got.size, 1)
})

test("the Feed skips a sync newer than FRESH_MS for the same follow list, per account", () => {
  const store = new Map()
  const storage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) }
  const me = hex("a"), other = hex("b"), follows = [hex("1"), hex("2")]
  assert.equal(syncedRecently(me, follows, { storage }), false, "never synced")
  markSynced(me, follows, { now: 1_000, storage })
  assert.equal(syncedRecently(me, follows, { now: 1_000 + FRESH_MS - 1, storage }), true)
  assert.equal(syncedRecently(me, follows, { now: 1_000 + FRESH_MS, storage }), false, "stale")
  assert.equal(syncedRecently(me, [...follows, hex("3")], { now: 1_001, storage }), false, "a new follow syncs at once")
  assert.equal(syncedRecently(other, follows, { now: 1_001, storage }), false, "another account")
  assert.notEqual(followsKey([hex("1"), hex("2")]), followsKey([hex("1"), hex("3")]))
  assert.equal(syncedRecently(me, follows, { storage: null }), false, "no storage: always sync")
})

test("thread roots are asked for once per page load: Haven /feed first, then the relays, misses again after a while", async t => {
  forgetRoots()
  if (globalThis.navigator?.onLine !== true) Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
  const inFeed = { id: hex("f", 1), kind: 1, pubkey: hex("1"), created_at: 1, tags: [], content: "" }
  const asked = []
  const vault = {
    feed: { query: async f => [inFeed].filter(e => f.ids.includes(e.id)) },
    outbox: { query: async () => [] },
  }
  const { pool } = await import("../src/net/pool.js")
  const remote = { id: hex("f", 2), kind: 1, pubkey: hex("2"), created_at: 1, tags: [], content: "" }
  t.mock.method(pool, "querySync", async (r, f) => { asked.push(f.ids); return [remote].filter(e => f.ids.includes(e.id)) })
  let clock = 1_000
  const fetchRoots = rootFetcher(vault, ["wss://r.example"], { names: async () => {}, now: () => clock })
  const missing = hex("f", 3)
  const first = await fetchRoots([inFeed.id, remote.id, missing])
  assert.equal(first.size, 2)
  assert.deepEqual(asked, [[remote.id, missing]], "the root in /feed isn't asked for")
  const back = await rootFetcher(vault, ["wss://r.example"], { names: async () => {}, now: () => clock })([inFeed.id, remote.id, missing])
  assert.equal(back.size, 2)
  assert.equal(asked.length, 1, "coming back asks nothing")
  clock += ROOT_RETRY_MS
  await fetchRoots([inFeed.id, remote.id, missing])
  assert.deepEqual(asked.at(-1), [missing], "only the miss, after ROOT_RETRY_MS")
})

test("the kept-lists store doesn't open (and so re-create) its database once its account has signed out", async () => {
  const me = hex("a", 70)
  let opens = 0
  const idb = { open: () => { opens++; return {} } }
  const out = wotStore(me, idb, () => undefined)
  assert.equal((await out.load()).lists.size, 0)
  await out.save([list(hex("1", 71), [hex("6")])], 1)
  assert.equal(opens, 0, "signed out: never opened")
  const other = wotStore(me, idb, () => hex("b", 72))
  await other.save([], 1)
  assert.equal(opens, 0, "another account signed in: never opened")
})
