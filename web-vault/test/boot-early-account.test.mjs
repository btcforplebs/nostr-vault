// Boot asks the account's relays while haven.wasm downloads (fetchAccount), then refreshAccount stores that answer
// and asks only the relays the early fetch didn't.
import test from "node:test"
import assert from "node:assert/strict"
import { pool } from "../src/net/pool.js"
import { accountQuery, fetchAccount, refreshAccount } from "../src/net/sync.js"

const me = "a".repeat(64)
const ev = (kind, created_at, tags = []) => ({ id: `${kind}-${created_at}`, pubkey: me, kind, created_at, tags, content: "", sig: "" })

function fakeVault() {
  const evs = []
  const outbox = { async event(e) { evs.push(e); return { ok: true } }, async query() { return evs } }
  return { outbox, evs }
}

test("refreshAccount stores the early answer and asks only the relays the early fetch didn't", async t => {
  const asked = [], opened = []
  t.mock.method(pool, "querySync", async relays => {
    asked.push(relays)
    return relays.includes("wss://relay.damus.io") ? [ev(3, 10, [["p", "b".repeat(64)]]), ev(10002, 10, [["r", "wss://read.example"]])] : [ev(0, 20)]
  })
  t.mock.method(pool, "ensureRelay", async url => { opened.push(url); return {} })
  const early = fetchAccount(me, ["wss://relay.damus.io", "wss://purplepag.es"])
  // Each relay is asked on its own (the account is used on the first relay that has it, sync.js accountQuery), so the
  // early fetch's own asks are the two relays, one query each.
  await early.all
  assert.deepEqual(asked, [["wss://relay.damus.io"], ["wss://purplepag.es"]])
  asked.length = 0
  const account = await refreshAccount(fakeVault(), me, ["wss://relay.damus.io/", "wss://purplepag.es", "wss://mine.example"], { early })
  assert.deepEqual(asked, [["wss://mine.example"]], "a trailing slash is the same relay")
  assert.deepEqual(account.follows, ["b".repeat(64)])
  assert.equal(account.profileEvent.kind, 0)
  assert.deepEqual(opened, ["wss://read.example"], "the feed's read relays open as soon as the early answer is in")
})

test("a failed early fetch still lets refreshAccount ask the rest", async t => {
  t.mock.method(pool, "querySync", async relays => { if (relays.includes("wss://relay.damus.io")) throw new Error("offline"); return [ev(3, 5)] })
  t.mock.method(pool, "ensureRelay", async () => ({}))
  const early = fetchAccount(me, ["wss://relay.damus.io"])
  const account = await refreshAccount(fakeVault(), me, ["wss://relay.damus.io", "wss://mine.example"], { early })
  assert.equal(account.contacts.kind, 3)
})

test("without an early fetch every hint relay is asked, as before", async t => {
  const asked = []
  t.mock.method(pool, "querySync", async relays => { asked.push(relays); return [] })
  await refreshAccount(fakeVault(), me, ["wss://relay.damus.io", "wss://mine.example"])
  assert.deepEqual(asked, [["wss://relay.damus.io"], ["wss://mine.example"]], "one query per relay, each asked once")
})

// The account is used on the first relay that has it plus a grace period (sync.js accountQuery), not when the last
// relay answers: relay.primal.net's socket never connected, and waiting for it held every cold start 2.5 s
// (NV_HEALTH_F_WEB: the account came in at 5.37 s in 9 of 11 runs).
const held = () => { let resolve; const promise = new Promise(r => { resolve = r }); return { promise, resolve } }
const wait = ms => new Promise(r => setTimeout(r, ms))

test("the account resolves on the first relay that has it plus the grace, not on the slowest relay", async t => {
  const slow = held()
  t.mock.method(pool, "querySync", relays => relays.includes("wss://slow.example") ? slow.promise : Promise.resolve([ev(0, 20)]))
  const q = accountQuery(["wss://fast.example", "wss://slow.example"], me, { graceMs: 40 })
  const t0 = Date.now()
  const evs = await q.events
  assert.ok(Date.now() - t0 < 1000, "answered on the grace, not on the slow relay")
  assert.deepEqual(evs.map(e => e.kind), [0], "what was in hand when the grace ended")
  slow.resolve([ev(3, 10, [["p", "b".repeat(64)]])])
  assert.deepEqual((await q.all).map(e => e.kind).sort(), [0, 3], "the slow relay's answer is still collected for the caller that stores it")
})

test("a relay with no account doesn't start the grace: the account's first real answer does", async t => {
  const acct = held()
  t.mock.method(pool, "querySync", relays => relays.includes("wss://acct.example") ? acct.promise : Promise.resolve([]))
  const q = accountQuery(["wss://empty.example", "wss://acct.example"], me, { graceMs: 40 })
  let settled = false
  q.events.then(() => { settled = true })
  await wait(80) // more than the grace: an empty answer must not have started it, nor finished the query
  assert.equal(settled, false, "still waiting for a relay that has the account")
  acct.resolve([ev(0, 20)])
  assert.deepEqual((await q.events).map(e => e.kind), [0])
})

test("a relay that answers after the grace still reaches Haven", async t => {
  const slow = held()
  t.mock.method(pool, "querySync", relays => relays.includes("wss://slow.example") ? slow.promise : Promise.resolve([ev(0, 20)]))
  t.mock.method(pool, "ensureRelay", async () => ({}))
  const v = fakeVault()
  const got = await refreshAccount(v, me, ["wss://fast.example", "wss://slow.example"])
  assert.equal(got.profileEvent.kind, 0)
  slow.resolve([ev(10006, 5, [["relay", "wss://blocked.example"]])])
  await wait(50) // the late answer is saved in the background; nothing waits on it
  assert.deepEqual(v.evs.map(e => e.kind).sort((a, b) => a - b), [0, 10006], "the Never Connect list on the slow relay wasn't dropped")
})

// Logen 2026-11-03: "Your vault didn't start: haven: no answer to EVENT in 15000 ms". A slow Haven ended the boot.
const slowVault = ({ failKinds = [], readFails = false } = {}) => {
  const evs = []
  const outbox = {
    async event(e) { if (failKinds.includes(e.kind)) throw new Error("haven: no answer to EVENT in 15000 ms"); evs.push(e); return { ok: true } },
    async query() { if (readFails) throw new Error("haven: no answer to REQ in 15000 ms"); return evs },
  }
  return { outbox, evs }
}

test("a save Haven doesn't answer is skipped and logged; the refresh carries on with it", async t => {
  t.mock.method(pool, "querySync", async () => [ev(0, 20), ev(3, 10, [["p", "b".repeat(64)]]), ev(10002, 10, [["r", "wss://read.example"]])])
  t.mock.method(pool, "ensureRelay", async () => ({}))
  const logs = [], v = slowVault({ failKinds: [3] })
  const account = await refreshAccount(v, me, ["wss://mine.example"], { log: (type, d) => logs.push([type, d]) })
  assert.deepEqual(account.follows, ["b".repeat(64)], "the follow list that wasn't saved still counts")
  assert.equal(account.profileEvent.kind, 0)
  assert.deepEqual(v.evs.map(e => e.kind).sort((a, b) => a - b), [0, 10002], "the other saves went on")
  assert.deepEqual(logs, [["account-store-failed", { kind: 3, err: "haven: no answer to EVENT in 15000 ms" }]])
})

test("Haven slow to save and to read: the refresh still returns what the relays sent", async t => {
  t.mock.method(pool, "querySync", async () => [ev(0, 20), ev(3, 10, [["p", "c".repeat(64)]])])
  t.mock.method(pool, "ensureRelay", async () => ({}))
  const logs = []
  const account = await refreshAccount(slowVault({ failKinds: [0, 3], readFails: true }), me, ["wss://mine.example"], { log: type => logs.push(type) })
  assert.deepEqual(account.follows, ["c".repeat(64)])
  assert.deepEqual(logs, ["account-store-failed", "account-store-failed", "account-read-failed"])
})

test("a refusal (not a timeout) still keeps the refused event out, as before", async t => {
  t.mock.method(pool, "querySync", async () => [ev(3, 10, [["p", "d".repeat(64)]])])
  const vault = { outbox: { async event() { return { ok: false, message: "blocked: nope" } }, async query() { return [] } } }
  const logs = []
  const account = await refreshAccount(vault, me, ["wss://mine.example"], { log: type => logs.push(type) })
  assert.deepEqual(account.follows, [])
  assert.deepEqual(logs, ["account-store-refused"])
})
