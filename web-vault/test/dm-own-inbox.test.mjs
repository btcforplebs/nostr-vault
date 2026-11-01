// The user's own DM inbox lookup settles early (ownDmRelays): a new account with no 10050/10002 gets its empty
// Messages without waiting on the slowest lookup relay, and an inbox only a slow relay knew about is reported later.
// Throwaway keys and a stubbed network: nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { ownDmRelays } from "../src/net/dms.js"

const B = generateSecretKey(), me = getPublicKey(B)
const later = (ms, v) => new Promise(r => setTimeout(() => r(v), ms))

test("own inbox: nothing found settles once half the relays answered, not after the slow one", async () => {
  const query = async ([url]) => url === "wss://slow" ? later(400, []) : []
  const t0 = Date.now()
  const { early, full } = ownDmRelays(me, ["wss://a", "wss://b", "wss://slow"], { query })
  assert.deepEqual(await early, [])
  assert.ok(Date.now() - t0 < 200, `early took ${Date.now() - t0} ms`)
  assert.deepEqual(await full, [])
})

test("own inbox: a 10050 from an early relay is used at once", async () => {
  const inbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://inbox.example/"]], content: "" }, B)
  const query = async ([url]) => url === "wss://a" ? [inbox] : url === "wss://slow" ? later(300, []) : []
  const { early } = ownDmRelays(me, ["wss://a", "wss://b", "wss://slow"], { query })
  assert.deepEqual(await early, ["wss://inbox.example"])
})

test("own inbox: an inbox only the slow relay had is reported through onLater", async () => {
  const inbox = finalizeEvent({ kind: 10050, created_at: 2, tags: [["relay", "wss://late-inbox.example"]], content: "" }, B)
  const query = async ([url]) => url === "wss://slow" ? later(150, [inbox]) : []
  let missed = null
  const { early, full } = ownDmRelays(me, ["wss://a", "wss://b", "wss://slow"], { query, onLater: m => { missed = m } })
  assert.deepEqual(await early, [])
  assert.deepEqual(await full, ["wss://late-inbox.example"])
  assert.deepEqual(missed, ["wss://late-inbox.example"])
})

test("own inbox: failed relays don't hold it, and all failing still settles", async () => {
  const query = async () => { throw new Error("refused") }
  const { early, full } = ownDmRelays(me, ["wss://a", "wss://b"], { query })
  assert.deepEqual(await early, [])
  assert.deepEqual(await full, [])
})

test("own inbox: someone else's list is ignored", async () => {
  const other = finalizeEvent({ kind: 10050, created_at: 9, tags: [["relay", "wss://evil.example"]], content: "" }, generateSecretKey())
  const { early } = ownDmRelays(me, ["wss://a"], { query: async () => [other] })
  assert.deepEqual(await early, [])
})
