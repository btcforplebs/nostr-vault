// The pool's one verifier (net/pool.js verifyRelayEvent): libsecp256k1 in wasm once loaded, pure JS before that. Both
// must refuse the same things: a changed field (the id is recomputed), another key's signature, a malformed id or
// signature, and a short signature that the wasm copy would otherwise fill from the last event checked.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey, verifyEvent as verifyInJs } from "nostr-tools/pure"
import { pool, verifierReady, verifyRelayEvent } from "../src/net/pool.js"

const sk = generateSecretKey(), other = generateSecretKey()
const signed = (key = sk, over = {}) => ({ ...finalizeEvent({ kind: 1, created_at: 1_700_000_000, tags: [["e", "a".repeat(64)]], content: "hello", ...over }, key) })
// A fresh plain copy: no cached "verified" flag carried over from signing.
const plain = ev => JSON.parse(JSON.stringify(ev))

const cases = () => {
  const good = plain(signed())
  const changed = { ...plain(good), content: "hellO" }
  const otherSig = { ...plain(good), sig: plain(signed(other)).sig }
  const swapped = { ...plain(signed(other)), pubkey: good.pubkey }
  return [
    ["a good event", good, true],
    ["changed content", changed, false],
    ["changed tag", { ...plain(good), tags: [["e", "b".repeat(64)]] }, false],
    ["another key's signature", otherSig, false],
    ["another key's event, my pubkey", swapped, false],
    ["upper-case id", { ...plain(good), id: good.id.toUpperCase() }, false],
    ["short signature", { ...plain(good), sig: good.sig.slice(0, 126) }, false],
    ["empty signature", { ...plain(good), sig: "" }, false],
    ["non-hex signature", { ...plain(good), sig: "z" + good.sig.slice(1) }, false],
    ["missing id", { ...plain(good), id: undefined }, false],
    ["number in a tag", { ...plain(good), tags: [["e", 5]] }, false],
  ]
}

test("the pool checks every relay event with verifyRelayEvent", () => {
  assert.equal(pool.verifyEvent, verifyRelayEvent)
})

test("the JS check (used until the wasm loads) gives these answers", () => {
  for (const [name, ev, want] of cases()) assert.equal(verifyInJs(ev), want, name)
})

test("with the wasm verifier, the same answers", async () => {
  assert.equal(await verifierReady, true, "node has WebAssembly and DecompressionStream: the wasm verifier loads")
  for (const [name, ev, want] of cases()) assert.equal(verifyRelayEvent(ev), want, name)
})

test("a short signature right after a good event is refused (no leftover bytes)", async () => {
  await verifierReady
  const good = plain(signed())
  assert.equal(verifyRelayEvent(good), true)
  assert.equal(verifyRelayEvent({ ...plain(good), sig: "" }), false)
  assert.equal(verifyRelayEvent({ ...plain(good), sig: good.sig.slice(0, 64) }), false)
})
