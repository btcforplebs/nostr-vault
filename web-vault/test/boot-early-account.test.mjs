// Boot asks the account's relays while haven.wasm downloads (fetchAccount), then refreshAccount stores that answer
// and asks only the relays the early fetch didn't.
import test from "node:test"
import assert from "node:assert/strict"
import { pool } from "../src/net/pool.js"
import { fetchAccount, refreshAccount } from "../src/net/sync.js"

const me = "a".repeat(64)
const ev = (kind, created_at, tags = []) => ({ id: `${kind}-${created_at}`, pubkey: me, kind, created_at, tags, content: "", sig: "" })

function fakeVault() {
  const evs = []
  const outbox = { async event(e) { evs.push(e); return { ok: true } }, async query() { return evs } }
  return { outbox }
}

test("refreshAccount stores the early answer and asks only the relays the early fetch didn't", async t => {
  const asked = [], opened = []
  t.mock.method(pool, "querySync", async relays => {
    asked.push(relays)
    return relays.includes("wss://relay.damus.io") ? [ev(3, 10, [["p", "b".repeat(64)]]), ev(10002, 10, [["r", "wss://read.example"]])] : [ev(0, 20)]
  })
  t.mock.method(pool, "ensureRelay", async url => { opened.push(url); return {} })
  const early = fetchAccount(me, ["wss://relay.damus.io", "wss://purplepag.es"])
  const account = await refreshAccount(fakeVault(), me, ["wss://relay.damus.io/", "wss://purplepag.es", "wss://mine.example"], { early })
  assert.deepEqual(asked, [["wss://relay.damus.io", "wss://purplepag.es"], ["wss://mine.example"]], "a trailing slash is the same relay")
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
  assert.deepEqual(asked, [["wss://relay.damus.io", "wss://mine.example"]])
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
