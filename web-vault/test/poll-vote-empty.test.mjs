// A vote whose picks match no option must not be signed: the newest 1018 per pubkey wins, so an empty one would
// silently withdraw the user's real vote. Test keys only; the throw comes before any signer or relay is touched.
import test from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { pool } from "../src/net/pool.js"
import { sendVote } from "../src/components/poll-votes.js"

test("sendVote refuses picks that match no option, and publishes nothing", async () => {
  const poll = { id: "a".repeat(64), pubkey: getPublicKey(generateSecretKey()), options: [{ id: "x", label: "X" }], multiple: false, relays: [] }
  let published = 0
  const real = pool.publish
  pool.publish = (...a) => { published++; return [] }
  try {
    await assert.rejects(sendVote({}, poll, ["nope"]), /no valid pick/)
    await assert.rejects(sendVote({}, poll, []), /no valid pick/)
  } finally { pool.publish = real }
  assert.equal(published, 0)
})
