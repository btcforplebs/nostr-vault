// Each relay's copy of the same event used to be signature-checked from scratch (Tidy's perf audit 11-20, W9). A copy
// that is exactly a checked one (same id, sig and pubkey, fields hashing to that id) skips only schnorr; anything else
// under a known id is checked in full and fails as before. Throwaway keys; nothing is published.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { verifyRelayEvent, forgetVerified, verifyCounts, VERIFIED_MAX } from "../src/net/pool.js"

const sk = generateSecretKey(), other = generateSecretKey()
const sign = (t, k = sk) => JSON.parse(JSON.stringify(finalizeEvent({ kind: 1, created_at: 1_700_000_000, tags: [["p", "a".repeat(64)]], content: "hello", ...t }, k)))
const copy = ev => JSON.parse(JSON.stringify(ev)) // a relay's own copy: a new object every time
const counts = () => ({ ...verifyCounts })
const delta = (before) => ({ full: verifyCounts.full - before.full, repeat: verifyCounts.repeat - before.repeat })

test("a second relay's copy of a checked event skips the signature check", () => {
  forgetVerified()
  const ev = sign()
  let c = counts()
  assert.equal(verifyRelayEvent(copy(ev)), true)
  assert.deepEqual(delta(c), { full: 1, repeat: 0 })
  c = counts()
  for (let i = 0; i < 5; i++) assert.equal(verifyRelayEvent(copy(ev)), true)
  assert.deepEqual(delta(c), { full: 0, repeat: 5 })
})

test("a changed content, tag, kind, time or pubkey under a known id is checked in full and refused", () => {
  forgetVerified()
  const ev = sign()
  assert.equal(verifyRelayEvent(copy(ev)), true)
  const forged = [
    { ...copy(ev), content: "forged" },
    { ...copy(ev), tags: [["p", "b".repeat(64)]] },
    { ...copy(ev), tags: [] },
    { ...copy(ev), kind: 7 },
    { ...copy(ev), created_at: ev.created_at + 1 },
    { ...copy(ev), pubkey: getPublicKey(other) },
  ]
  for (const f of forged) {
    const c = counts()
    assert.equal(verifyRelayEvent(f), false, JSON.stringify(f).slice(0, 80))
    assert.deepEqual(delta(c), { full: 1, repeat: 0 }, "never taken as a repeat")
  }
  assert.equal(verifyRelayEvent(copy(ev)), true, "the real one still passes")
})

test("a changed sig under a known id is checked in full: a bad one fails, another valid one passes", () => {
  forgetVerified()
  const ev = sign()
  assert.equal(verifyRelayEvent(copy(ev)), true)
  let c = counts()
  assert.equal(verifyRelayEvent({ ...copy(ev), sig: "0".repeat(128) }), false)
  assert.equal(verifyRelayEvent({ ...copy(ev), sig: ev.sig.slice(0, -1) + (ev.sig.at(-1) === "0" ? "1" : "0") }), false)
  assert.deepEqual(delta(c), { full: 2, repeat: 0 })
  // Schnorr signatures carry fresh randomness: signing the same event again gives the same id and another valid sig.
  const again = sign({}, sk)
  assert.equal(again.id, ev.id); assert.notEqual(again.sig, ev.sig)
  c = counts()
  assert.equal(verifyRelayEvent(copy(again)), true)
  assert.deepEqual(delta(c), { full: 1, repeat: 0 })
})

test("a malformed event is never a repeat, whatever its id", () => {
  forgetVerified()
  const ev = sign()
  assert.equal(verifyRelayEvent(copy(ev)), true)
  for (const bad of [{ ...copy(ev), tags: [[1]] }, { ...copy(ev), content: 5 }, { ...copy(ev), kind: "1" }, {}]) {
    assert.equal(verifyRelayEvent(bad), false)
  }
})

test("the memory is bounded: VERIFIED_MAX ids, the oldest checked again", () => {
  forgetVerified()
  const first = sign({ content: "first" })
  assert.equal(verifyRelayEvent(copy(first)), true)
  for (let i = 0; i < VERIFIED_MAX; i++) verifyRelayEvent({ id: i.toString(16).padStart(64, "0") }) // malformed: not kept
  let c = counts()
  verifyRelayEvent(copy(first))
  assert.deepEqual(delta(c), { full: 0, repeat: 1 }, "failures are never remembered, so they don't push anything out")
  for (let i = 0; i < 40; i++) verifyRelayEvent(copy(sign({ content: `n${i}` })))
  assert.ok(VERIFIED_MAX > 40)
})

test("a big event (a long contact list) is always checked in full: hashing it again costs more than the check", () => {
  forgetVerified()
  const big = sign({ kind: 3, tags: Array.from({ length: 51 }, (_, i) => ["p", i.toString(16).padStart(64, "a")]) })
  const c = counts()
  assert.equal(verifyRelayEvent(copy(big)), true)
  assert.equal(verifyRelayEvent(copy(big)), true)
  assert.deepEqual(delta(c), { full: 2, repeat: 0 })
})
