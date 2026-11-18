// A relay that sends a forged copy of an event (the real id, changed content or a bad signature) must not hide the
// real one. nostr-tools marks an id seen when it arrives, before the copy is verified, so the real event that came
// after a forgery was dropped as a duplicate (Tron, PR 2195). Here an id counts as seen only once a copy of it has
// passed verification and been delivered; a copy that fails is refused and blocks nothing.
import test from "node:test"
import assert from "node:assert/strict"
import { finalizeEvent, generateSecretKey } from "nostr-tools/pure"
import { LivePool } from "../src/net/pool.js"

const sk = generateSecretKey()
const real = JSON.parse(JSON.stringify(finalizeEvent({ kind: 1, created_at: 1_700_000_000, tags: [], content: "the real note" }, sk)))
const forgedContent = { ...real, content: "a forged note" }
const forgedSig = { ...real, sig: "0".repeat(128) }

// An in-memory relay: answers each REQ with the events planned for its URL, in order, then EOSE.
const plans = new Map()
class FakeSocket {
  static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3
  constructor(url) { this.url = url; this.readyState = 0; setTimeout(() => { this.readyState = 1; this.onopen?.() }) }
  send(raw) {
    const [type, id] = JSON.parse(raw)
    if (type !== "REQ") return
    const plan = plans.get(this.url.replace(/\/$/, "")) ?? []
    setTimeout(() => {
      for (const ev of plan) this.onmessage?.({ data: JSON.stringify(["EVENT", id, ev]) })
      this.onmessage?.({ data: JSON.stringify(["EOSE", id]) })
    }, plan.delay ?? 0)
  }
  close() { this.readyState = 3; this.onclose?.({}) }
}
const run = async relays => {
  plans.clear()
  for (const [u, evs, delay] of relays) { const p = [...evs]; p.delay = delay; plans.set(u, p) }
  const pool = new LivePool({ websocketImplementation: FakeSocket })
  try {
    const got = []
    await new Promise(resolve => {
      const sub = pool.subscribeMany(relays.map(r => r[0]), { kinds: [1] }, { onevent: ev => got.push(ev), oneose: () => { sub.close(); resolve() }, maxWait: 3000 })
    })
    return got
  } finally { pool.destroy() }
}
const A = "wss://a.example", B = "wss://b.example"

test("a forged copy first does not hide the real event (same relay)", async () => {
  for (const forged of [forgedContent, forgedSig]) {
    const got = await run([[A, [forged, real]]])
    assert.deepEqual(got.map(e => e.content), ["the real note"])
    assert.equal(got[0].sig, real.sig)
  }
})

test("a forged copy from one relay does not hide the real event from another", async () => {
  const got = await run([[A, [forgedContent]], [B, [real], 50]])
  assert.deepEqual(got.map(e => e.content), ["the real note"])
})

test("the real event is still delivered once, whichever relays repeat it or forge it after", async () => {
  assert.equal((await run([[A, [real]], [B, [real], 50]])).length, 1)
  assert.equal((await run([[A, [real, real, forgedContent]]])).length, 1)
  assert.deepEqual((await run([[A, [real]], [B, [forgedSig, real], 50]])).map(e => e.content), ["the real note"])
})
