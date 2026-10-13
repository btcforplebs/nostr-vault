// Where a note posted from the web app goes: the write list plus the iPhone app's broadcast set, without dead
// hosts, and this machine's loopback relay only when the page itself is open on this machine.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { BROADCAST_RELAYS, pool, publishRelays } from "../src/net/pool.js"
import { publishNote } from "../src/net/sync.js"

// Logen's write list on 2026-10-13: the Mac's vault relay, nos.lol (timed out), btcforplebs.
const WRITE = ["ws://localhost:3355", "wss://nos.lol", "wss://relay.btcforplebs.com/"]

test("a short write list still goes out to the iPhone app's broadcast set, dead hosts dropped", () => {
  const { network, local } = publishRelays(WRITE, "vault.example.com")
  assert.deepEqual(network, ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"])
  assert.deepEqual(local, [])
})

test("the loopback relay is kept only for a page open on this machine", () => {
  for (const host of ["localhost", "127.0.0.1", "[::1]"]) assert.deepEqual(publishRelays(WRITE, host).local, ["ws://localhost:3355"], host)
  for (const host of ["192.168.1.20", "nostr-vault.local", ""]) assert.deepEqual(publishRelays(WRITE, host).local, [], host)
})

test("an empty or unusable write list falls back to the broadcast set", () => {
  assert.deepEqual(publishRelays([], "x").network, BROADCAST_RELAYS)
  assert.deepEqual(publishRelays(["not a url", "https://relay.damus.io"], "x").network, BROADCAST_RELAYS)
})

test("other write relays are kept, write list first", () => {
  assert.deepEqual(publishRelays(["wss://relay.primal.net", "wss://relay.damus.io"], "x").network,
    ["wss://relay.primal.net", "wss://relay.damus.io", "wss://relay.btcforplebs.com", "wss://relay.snort.social"])
})

test("publishNote sends to the chosen relays and marks the local one", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk) // throwaway key
  const signer = { signEvent: async tpl => finalizeEvent(tpl, sk) }
  const vault = { outbox: { event: async () => ({ ok: true, message: "" }) } }
  const sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push(...urls); return urls.map(u => u.includes("snort") ? Promise.reject(new Error("connection failed")) : Promise.resolve("")) })
  globalThis.location = { hostname: "localhost" }
  t.after(() => { delete globalThis.location })
  const res = await publishNote(vault, signer, pk, "hello", WRITE)
  assert.deepEqual(sent, ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social", "ws://localhost:3355"])
  assert.deepEqual(res.relays.map(r => [r.url, r.ok, r.local]), [
    ["wss://relay.btcforplebs.com", true, false], ["wss://relay.damus.io", true, false],
    ["wss://relay.snort.social", false, false], ["ws://localhost:3355", true, true],
  ])
  assert.equal(res.relays[2].message, "connection failed")
})
