// Where a note posted from the web app goes: the user's own write list only (Logen 2026-11-01: don't force relays on
// users), the recommended set when there is none, without dead hosts, and this machine's loopback relay only when
// the page itself is open on this machine.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { BROADCAST_RELAYS, DEFAULT_RELAYS, pool, publishRelays } from "../src/net/pool.js"
import { publishNote } from "../src/net/sync.js"

// Logen's write list on 2026-10-13: the Mac's vault relay, nos.lol (timed out), btcforplebs.
const WRITE = ["ws://localhost:3355", "wss://nos.lol", "wss://relay.btcforplebs.com/"]

test("a short write list goes only to the user's own relays: nothing forced on top, dead hosts dropped", () => {
  const { network, local } = publishRelays(WRITE, "vault.example.com")
  assert.deepEqual(network, ["wss://relay.btcforplebs.com"])
  assert.deepEqual(local, [])
  for (const r of BROADCAST_RELAYS) if (r !== "wss://relay.btcforplebs.com") assert.ok(!network.includes(r), `${r} not forced on`)
})

test("the loopback relay is kept only for a page open on this machine", () => {
  for (const host of ["localhost", "127.0.0.1", "[::1]"]) assert.deepEqual(publishRelays(WRITE, host).local, ["ws://localhost:3355"], host)
  for (const host of ["192.168.1.20", "nostr-vault.local", ""]) assert.deepEqual(publishRelays(WRITE, host).local, [], host)
})

test("no usable write relay at all: the recommended set a new account starts on", () => {
  assert.deepEqual(publishRelays([], "x").network, DEFAULT_RELAYS)
  assert.deepEqual(publishRelays(["not a url", "https://relay.damus.io"], "x").network, DEFAULT_RELAYS)
})

test("the write list as the user has it, in their order, and nothing else", () => {
  assert.deepEqual(publishRelays(["wss://relay.primal.net", "wss://relay.damus.io"], "x").network, ["wss://relay.primal.net", "wss://relay.damus.io"])
  assert.deepEqual(publishRelays(["wss://nostr.example/", "wss://nostr.example"], "x").network, ["wss://nostr.example"], "once each")
})

test("publishNote sends to the chosen relays and marks the local one", async t => {
  const sk = generateSecretKey(), pk = getPublicKey(sk) // throwaway key
  const signer = { signEvent: async tpl => finalizeEvent(tpl, sk) }
  const vault = { outbox: { event: async () => ({ ok: true, message: "" }) } }
  const sent = []
  t.mock.method(pool, "publish", (urls, ev) => { sent.push(...urls); return urls.map(u => u.includes("snort") ? Promise.reject(new Error("connection failed")) : Promise.resolve("")) })
  globalThis.location = { hostname: "localhost" }
  t.after(() => { delete globalThis.location })
  const write = [...WRITE, "wss://relay.snort.social"] // a write list with a relay that fails
  const res = await publishNote(vault, signer, pk, "hello", write)
  assert.deepEqual(sent, ["wss://relay.btcforplebs.com", "wss://relay.snort.social", "ws://localhost:3355"], "the write list only: no damus forced on")
  assert.deepEqual(res.relays.map(r => [r.url, r.ok, r.local]), [
    ["wss://relay.btcforplebs.com", true, false], ["wss://relay.snort.social", false, false], ["ws://localhost:3355", true, true],
  ])
  assert.equal(res.relays[1].message, "connection failed")
})
