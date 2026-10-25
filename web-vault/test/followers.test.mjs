// The profile's Followers count (net/followers.js): the largest single relay COUNT, as the iPhone's
// ProfileFeedLoader.fetchFollowerCount, with fake relays.
import test from "node:test"
import assert from "node:assert/strict"
import { fetchFollowers, keptFollowers, relayCount, COUNT_RELAYS } from "../src/net/followers.js"

const P = "a".repeat(64)

test("asks damus and primal, the relays the iPhone counts on", () => {
  assert.deepEqual(COUNT_RELAYS, ["wss://relay.damus.io", "wss://relay.primal.net"])
})

test("keeps the largest answer, never the sum; each new largest is drawn as it lands", async () => {
  const answers = { "wss://a": 120, "wss://b": 340, "wss://c": null }
  const filters = [], drawn = []
  const count = async (url, f) => { filters.push(f); await new Promise(r => setTimeout(r, answers[url] === 340 ? 5 : 0)); return answers[url] }
  const n = await fetchFollowers(P, c => drawn.push(c), { relays: Object.keys(answers), count })
  assert.equal(n, 340)
  assert.deepEqual(drawn, [120, 340])
  assert.deepEqual(filters[0], { kinds: [3], "#p": [P] })
  assert.equal(keptFollowers(P), 340, "kept for the next open")
})

test("nobody counts: null, and nothing drawn", async () => {
  const B = "b".repeat(64), drawn = []
  assert.equal(await fetchFollowers(B, c => drawn.push(c), { relays: ["wss://a"], count: async () => null }), null)
  assert.deepEqual(drawn, [])
  assert.equal(keptFollowers(B), undefined)
})

test("a kept count runs out", async () => {
  const C = "c".repeat(64)
  await fetchFollowers(C, () => {}, { relays: ["wss://a"], count: async () => 7, now: () => 0 })
  assert.equal(keptFollowers(C, 60_000), 7)
  assert.equal(keptFollowers(C, 11 * 60_000), undefined)
})

test("one relay: a refusal, a failure or a silent relay is null, not 0", async () => {
  const f = { kinds: [3], "#p": [P] }
  assert.equal(await relayCount("wss://x", f, { ensure: async () => ({ count: async () => 42 }) }), 42)
  assert.equal(await relayCount("wss://x", f, { ensure: async () => ({ count: () => Promise.reject(new Error("CLOSED")) }) }), null)
  assert.equal(await relayCount("wss://x", f, { ensure: async () => { throw new Error("dead") } }), null)
  assert.equal(await relayCount("wss://x", f, { ms: 20, ensure: async () => ({ count: () => new Promise(() => {}) }) }), null)
})
