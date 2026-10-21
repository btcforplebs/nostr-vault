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
