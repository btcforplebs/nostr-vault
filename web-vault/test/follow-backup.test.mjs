// Following Backup: only your own signed kind 3s are kept or restored, copies are capped at 50 newest, the diff names
// who you lost and who you added, and Restore keeps the current list first, dates the old one after it, and refuses
// when your relays can't be heard. Throwaway keys, a fake store and a stubbed pool: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { ownList, keepSnapshot, scanRelays, diffLists, restoreBase, restoreList, MAX_SNAPSHOTS, backupDbName } from "../src/net/follow-backup.js"

const SK = generateSecretKey(), ME = getPublicKey(SK)
const OTHER = generateSecretKey()
const P = n => n.toString(16).padStart(64, "0")
const list = (pks, created_at, sk = SK, extra = []) => finalizeEvent({ kind: 3, created_at, content: '{"wss://r.example":{"read":true,"write":true}}', tags: [...pks.map(p => ["p", P(p)]), ...extra] }, sk)
function memStore() {
  const m = new Map()
  return { m, all: async () => [...m.values()].sort((a, b) => b.created_at - a.created_at), put: async s => { m.set(s.id, s) }, remove: async id => { m.delete(id) } }
}

test("only your own, validly signed kind 3 counts; a tampered one doesn't", () => {
  const l = list([1, 2], 100)
  assert.ok(ownList(l, ME))
  assert.ok(!ownList(list([1], 100, OTHER), ME))
  assert.ok(!ownList({ ...l, tags: [["p", P(9)]] }, ME))
  assert.ok(!ownList({ ...l, kind: 10002 }, ME))
  assert.equal(backupDbName(ME), `haven:${ME}:followbackup`)
})

test("copies: each list once, empty lists skipped, only the newest 50 kept", async () => {
  const s = memStore()
  assert.equal(await keepSnapshot(s, list([1], 10), ME), true)
  assert.equal(await keepSnapshot(s, list([1], 10), ME), false, "the same list again (same id) is kept once")
  const same = list([2], 11)
  await keepSnapshot(s, same, ME)
  assert.equal(await keepSnapshot(s, same, ME), false)
  assert.equal(await keepSnapshot(s, list([], 12), ME), false)
  assert.equal(await keepSnapshot(s, list([1], 13, OTHER), ME), false)
  for (let i = 0; i < 60; i++) await keepSnapshot(s, list([i + 1], 1000 + i), ME)
  const all = await s.all()
  assert.equal(all.length, MAX_SNAPSHOTS)
  assert.equal(all.at(-1).created_at, 1010)
  assert.ok(all[0].savedAt > 0)
})

test("relay scan: your own lists once each, newest first, others' and forged dropped", async () => {
  const a = list([1], 10), b = list([1, 2], 20)
  let asked
  const r = await scanRelays(ME, ["wss://r.example"], { query: async (relays, f) => { asked = { relays, f }; return [a, b, a, list([3], 30, OTHER), { ...b, id: "x", content: "forged" }] } })
  assert.deepEqual(r.map(e => e.id), [b.id, a.id])
  assert.deepEqual(asked.f, { kinds: [3], authors: [ME], limit: 50 })
  assert.ok(asked.relays.includes("wss://purplepag.es"))
})

test("diff: who the old list has that you no longer follow, who you added since", () => {
  assert.deepEqual(diffLists(list([1, 2, 3], 20), list([2, 3, 4, 5], 10)), { removed: [P(4), P(5)], added: [P(1)] })
  assert.deepEqual(diffLists(null, list([1], 10)), { removed: [P(1)], added: [] })
})

function ctxWith(outbox = [], keep = { ok: true }) {
  const stored = []
  return {
    stored,
    session: { pubkey: ME },
    account: { relays: { read: ["wss://r.example"], write: ["wss://w.example"] } },
    signer: { signEvent: async t => finalizeEvent(t, SK) },
    vault: { outbox: { query: async () => outbox, event: async ev => { stored.push(ev); return keep } } },
  }
}

test("restore: current list kept first, the old one's tags signed after it with the current content, sent to your write relays", async t => {
  const cur = finalizeEvent({ kind: 3, created_at: Math.floor(Date.now() / 1000) + 100, content: '{"wss://new.example":{"read":true,"write":true}}', tags: [["p", P(1)]] }, SK) // a clock ahead
  const old = list([1, 2, 3], 50, SK, [["t", "nostr"]])
  const ctx = ctxWith(), s = memStore()
  let sent
  t.mock.method(pool, "publish", (urls, ev) => { sent = { urls, ev }; return urls.map(() => Promise.resolve("")) })
  const ask = async () => ({ events: [cur], answered: true })
  const { event } = await restoreList({ ctx, old, shown: cur, store: s, ask })
  assert.deepEqual(event.tags, old.tags)
  assert.equal(event.content, cur.content, "the relays your other apps use now aren't rolled back")
  assert.equal(event.created_at, cur.created_at + 1)
  assert.ok(sent.urls.includes("wss://w.example"))
  assert.deepEqual([...s.m.keys()], [cur.id], "the list it replaced is kept")
  assert.deepEqual(ctx.stored.map(e => e.id), [event.id])
})

test("restore refuses: relays unheard, someone else's list, an empty list, or no relay took it", async t => {
  const ctx = ctxWith()
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.reject(new Error("no"))))
  await assert.rejects(restoreList({ ctx, old: list([1], 5), ask: async () => ({ events: [], answered: false }) }), /Not enough of your relays/)
  await assert.rejects(restoreList({ ctx, old: list([1], 5, OTHER), ask: async () => ({ events: [], answered: true }) }), /isn't one you signed/)
  await assert.rejects(restoreList({ ctx, old: list([], 5), ask: async () => ({ events: [], answered: true }) }), /follows nobody/)
  await assert.rejects(restoreList({ ctx, old: list([1], 5), store: memStore(), ask: async () => ({ events: [list([2], 9)], answered: true }) }), /No relay took it/)
  assert.deepEqual(ctx.stored, [])
})

test("restore refuses when no current list is found: nothing to keep first, so it couldn't be undone", async t => {
  const ctx = ctxWith(), s = memStore()
  let sent = false
  t.mock.method(pool, "publish", urls => { sent = true; return urls.map(() => Promise.resolve("")) })
  const ask = async () => ({ events: [], answered: true })
  await assert.rejects(restoreBase({ ctx, ask }), /wasn't found on your relays/)
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), store: s, ask }), /wasn't found on your relays/)
  assert.equal(sent, false)
  assert.deepEqual(ctx.stored, [])
})

test("restore refuses when the current list can't be kept first", async t => {
  const cur = list([1], 100), ctx = ctxWith()
  let sent = false
  t.mock.method(pool, "publish", urls => { sent = true; return urls.map(() => Promise.resolve("")) })
  const ask = async () => ({ events: [cur], answered: true })
  const full = { ...memStore(), put: async () => { throw new Error("QuotaExceededError") } }
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), shown: cur, store: full, ask }), /couldn't be saved.*QuotaExceededError.*nothing was changed/)
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), shown: cur, ask }), /couldn't be saved/, "no store, no copy")
  const silent = { ...memStore(), put: async () => {} } // a write that resolves but keeps nothing
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), shown: cur, store: silent, ask }), /couldn't be saved/)
  assert.equal(sent, false)
})

test("restore refuses when the newest list isn't the one the change was shown against", async t => {
  const seen = list([1], 100), newer = list([1, 9], 200), ctx = ctxWith(), s = memStore()
  let sent = false
  t.mock.method(pool, "publish", urls => { sent = true; return urls.map(() => Promise.resolve("")) })
  const ask = async () => ({ events: [newer], answered: true })
  assert.equal((await restoreBase({ ctx, ask })).id, newer.id, "the confirm is built from the list restore will replace")
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), shown: seen, store: s, ask }), /changed since you looked/)
  assert.equal(sent, false)
})

test("restore reports a vault that refuses the restored list", async t => {
  const cur = list([1], 100), ctx = ctxWith([], { ok: false, message: "blocked: nope" }), s = memStore()
  t.mock.method(pool, "publish", urls => urls.map(() => Promise.resolve("")))
  await assert.rejects(restoreList({ ctx, old: list([1, 2], 5), shown: cur, store: s, ask: async () => ({ events: [cur], answered: true }) }), /Haven refused the follow list: blocked: nope/)
})
