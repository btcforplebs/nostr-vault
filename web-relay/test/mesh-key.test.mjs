import { test } from "node:test"
import assert from "node:assert/strict"
import { loadMeshSecret, KEY_ITEM } from "../src/fips/mesh-key.js"

const memStorage = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const memKs = () => { const m = new Map(); return { m, get: async n => m.get(n), add: async (n, k) => { if (m.has(n)) throw new Error("exists"); m.set(n, k) } } }
const hex = b => Buffer.from(b).toString("hex")

test("a new key is stored sealed, never as plain hex, and reads back the same", async () => {
  const s = memStorage(), ks = memKs()
  const a = await loadMeshSecret(s, { ks })
  assert.equal(a.length, 32)
  const stored = s.getItem(KEY_ITEM)
  assert.doesNotMatch(stored, /^[0-9a-f]{64}$/)
  assert.ok(!stored.includes(hex(a)), "the secret is not in the stored copy")
  assert.equal(JSON.parse(stored).v, 1)
  assert.equal(ks.m.get("mesh-wrap").extractable, false, "the wrapping key can't be exported")
  assert.equal(hex(await loadMeshSecret(s, { ks })), hex(a), "same key the next time")
})

test("a plain key from before is sealed in place, the same key", async () => {
  const s = memStorage(), ks = memKs(), old = "ab".repeat(32)
  s.setItem(KEY_ITEM, old)
  assert.equal(hex(await loadMeshSecret(s, { ks })), old)
  assert.notEqual(s.getItem(KEY_ITEM), old)
  assert.equal(hex(await loadMeshSecret(s, { ks })), old, "the address does not change")
})

test("a sealed key whose wrapping key is gone is an error, never replaced", async () => {
  const s = memStorage(), ks = memKs()
  await loadMeshSecret(s, { ks })
  const sealed = s.getItem(KEY_ITEM)
  await assert.rejects(loadMeshSecret(s, { ks: memKs() }), /can't be read/)
  assert.equal(s.getItem(KEY_ITEM), sealed, "left as it was")
})

test("garbage and tampered values are errors, never replaced", async () => {
  const ks = memKs(), s = memStorage()
  await loadMeshSecret(s, { ks })
  const box = JSON.parse(s.getItem(KEY_ITEM))
  box.ct = Buffer.from(Buffer.from(box.ct, "base64").map((b, i) => (i === 0 ? b ^ 1 : b))).toString("base64")
  s.setItem(KEY_ITEM, JSON.stringify(box))
  await assert.rejects(loadMeshSecret(s, { ks }), /can't be read/)
  const g = memStorage(); g.setItem(KEY_ITEM, "not a key")
  await assert.rejects(loadMeshSecret(g, { ks }), /can't be read/)
  assert.equal(g.getItem(KEY_ITEM), "not a key")
})

test("without IndexedDB (tests, old browsers) the key stays plain hex, as before", async () => {
  const s = memStorage()
  const a = await loadMeshSecret(s)
  assert.equal(s.getItem(KEY_ITEM), hex(a))
})
