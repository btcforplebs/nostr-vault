// The page's NIP-01 client over one Haven stream, against the contract stub.
import { test } from "node:test"
import assert from "node:assert/strict"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import { wrap } from "../src/haven/haven.js"
import { HavenClient } from "../src/haven/client.js"
import { havenStub } from "./support/haven-stub.js"

const note = (sk, content) => finalizeEvent({ kind: 1, created_at: 1760000000, tags: [], content }, sk)

async function setup() {
  const owner = generateSecretKey(), test_ = generateSecretKey(), stranger = generateSecretKey()
  const stub = havenStub()
  const haven = wrap(stub)
  await haven.start({ ownerNpub: npubEncode(getPublicKey(owner)), whitelist: [npubEncode(getPublicKey(test_))] })
  return { stub, haven, owner, test_, stranger, c: new HavenClient(haven.conn("page", { mode: "nip01", route: "/" }), { timeoutMs: 500 }) }
}

test("event / query / count round trip, with the outbox write rule", async () => {
  const { c, owner, test_, stranger } = await setup()
  const a = note(owner, "owner"), b = note(test_, "whitelisted"), x = note(stranger, "stranger")
  assert.deepEqual(await c.event(a), { ok: true, message: "" })
  assert.equal((await c.event(b)).ok, true)
  const r = await c.event(x)
  assert.equal(r.ok, false)
  assert.match(r.message, /^restricted:/)
  assert.equal((await c.event({ ...a, content: "tampered" })).ok, false)
  assert.deepEqual((await c.query({ kinds: [1] })).map(e => e.id).sort(), [a.id, b.id].sort())
  assert.deepEqual(await c.query([{ ids: [a.id] }, { ids: [b.id] }]).then(es => es.length), 2)
  assert.equal(await c.count({ kinds: [1] }), 2)
})

test("a query closes its subscription after EOSE, so later events don't leak into it", async () => {
  const { c, stub, owner } = await setup()
  await c.query({ kinds: [1] })
  await c.event(note(owner, "after"))
  await new Promise(r => setTimeout(r, 20))
  assert.equal(c.pending.size, 0)
  assert.equal(stub.evs.size, 1)
})

test("lines split across chunks are reassembled", async () => {
  let onData
  const c = new HavenClient({ write() {}, onData: cb => (onData = cb), onClose() {}, close() {} })
  const p = c.count({ kinds: [1] })
  const line = new TextEncoder().encode(JSON.stringify(["COUNT", "c1", { count: 7 }]) + "\n")
  onData(line.subarray(0, 5)); onData(line.subarray(5))
  assert.equal(await p, 7)
})

test("a closed stream rejects pending and new requests", async () => {
  const { c, owner } = await setup()
  const p = c.query({ kinds: [1] })
  c.close()
  await assert.rejects(p, /closed/)
  await assert.rejects(c.event(note(owner, "x")), /closed/)
})
