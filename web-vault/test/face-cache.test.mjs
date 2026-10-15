// The globe's face-picture cache (net/face-cache.js): bounded, least recently used dropped first, loads in flight kept.
import test from "node:test"
import assert from "node:assert/strict"
import { faceCache, FACE_MAX, FACE_PX } from "../src/net/face-cache.js"

test("pictures are small and the cache is bounded", () => {
  assert.equal(FACE_PX, 64)
  assert.equal(FACE_MAX, 600)
  const dropped = []
  const c = faceCache({ onDrop: e => dropped.push(e) })
  for (let i = 0; i < 3000; i++) c.set(`u${i}`, { id: i })
  assert.equal(c.size, FACE_MAX, "3,000 follows can't grow it past the cap")
  assert.equal(dropped.length, 3000 - FACE_MAX)
  assert.ok(c.has("u2999") && !c.has("u0"))
})

test("the least recently drawn picture goes first; drawing one keeps it", () => {
  const dropped = []
  const c = faceCache({ max: 3, onDrop: e => dropped.push(e) })
  c.set("a", "A"); c.set("b", "B"); c.set("c", "C")
  c.get("a") // drawn this frame
  c.set("d", "D")
  assert.deepEqual(dropped, ["B"])
  assert.ok(c.has("a") && c.has("c") && c.has("d"))
  assert.equal(c.get("zzz"), undefined)
})

test("a load in flight isn't dropped (it would only start again); it may go over the cap until it lands", () => {
  const c = faceCache({ max: 2 })
  c.set("a", "loading"); c.set("b", "loading"); c.set("c", "loading")
  assert.equal(c.size, 3)
  c.set("a", "A") // landed
  c.set("d", "D")
  assert.ok(!c.has("a"), "the oldest finished one goes"); assert.ok(c.has("b") && c.has("c"))
})
