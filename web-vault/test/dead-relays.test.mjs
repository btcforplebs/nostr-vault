// A relay the iPhone app has marked dead must not slow any read: no default or NIP-65 list carries it, and the
// pool refuses to open it, so a query that names it answers at once instead of waiting out its timeout.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { DEAD_RELAY_HOSTS, DEFAULT_RELAYS, pool, relayLists } from "../src/net/pool.js"

after(() => pool.destroy())

const hostOf = url => new URL(url).hostname

test("the default read set carries no dead host", () => {
  assert.deepEqual(DEFAULT_RELAYS.filter(u => DEAD_RELAY_HOSTS.has(hostOf(u))), [])
})

test("a NIP-65 list drops dead hosts from read and write, and falls back when nothing live is left", () => {
  const ev = { tags: [["r", "wss://nos.lol/"], ["r", "wss://relay.primal.net"], ["r", "wss://NOSTR.MOM", "read"], ["r", "wss://offchain.pub", "write"]] }
  assert.deepEqual(relayLists(ev), { read: ["wss://relay.primal.net"], write: ["wss://relay.primal.net"] })
  assert.deepEqual(relayLists({ tags: [["r", "wss://nos.lol"]] }), { read: DEFAULT_RELAYS, write: DEFAULT_RELAYS })
})

test("a query naming only dead relays answers at once without opening them", async () => {
  const dead = ["wss://nos.lol", "wss://nostr.mom/", "wss://offchain.pub"]
  const t0 = Date.now()
  const evs = await pool.querySync(dead, { kinds: [1], limit: 1 }, { maxWait: 5000 })
  assert.deepEqual(evs, [])
  assert.ok(Date.now() - t0 < 250, `querySync took ${Date.now() - t0} ms`)
  assert.deepEqual([...pool.relays.keys()].filter(u => DEAD_RELAY_HOSTS.has(hostOf(u))), [])
})

test("a direct ensureRelay on a dead host is refused before any connection", async () => {
  await assert.rejects(pool.ensureRelay("wss://nos.lol", { connectionTimeout: 5000 }), /dead relay/)
  assert.equal(pool.relays.has("wss://nos.lol/"), false)
})

test("a bunker's own relay is never refused, even on a dead host; other reads there still are", async t => {
  const base = Object.getPrototypeOf(Object.getPrototypeOf(pool)) // SimplePool's ensureRelay: no real connection here
  t.mock.method(base, "ensureRelay", async url => ({ url }))
  await assert.rejects(pool.ensureRelay("wss://nostr.mom"), /dead relay/)
  pool.keepForSigner(["wss://nostr.mom/"])
  assert.deepEqual(await pool.ensureRelay("wss://nostr.mom"), { url: "wss://nostr.mom" })
  await assert.rejects(pool.ensureRelay("wss://offchain.pub"), /dead relay/)
  t.after(() => pool.signerRelays.clear())
})
