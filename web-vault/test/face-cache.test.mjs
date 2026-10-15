// The globe's face-picture cache (net/face-cache.js): bounded, least recently used dropped first, loads in flight kept.
import test from "node:test"
import assert from "node:assert/strict"
import { faceCache, FACE_MAX, FACE_PX } from "../src/net/face-cache.js"

test("pictures are small and the cache is bounded", () => {
  assert.equal(FACE_PX, 64)
  assert.equal(FACE_MAX, 600)
  const dropped = []
  const c = faceCache({ onDrop: e => dropped.push(e) })
  for (let i = 0; i < 3000; i++) { c.frame(); c.set(`u${i}`, { id: i }) } // one face per frame, each gone the next
  assert.equal(c.size, FACE_MAX, "3,000 follows can't grow it past the cap")
  assert.equal(dropped.length, 3000 - FACE_MAX)
  assert.ok(c.has("u2999") && !c.has("u0"))
})

test("the least recently drawn picture goes first; drawing one keeps it", () => {
  const dropped = []
  const c = faceCache({ max: 3, onDrop: e => dropped.push(e) })
  c.frame(); c.set("a", "A"); c.set("b", "B"); c.set("c", "C")
  c.frame(); c.get("a") // drawn this frame
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
  c.frame(); c.set("d", "D")
  assert.ok(!c.has("a"), "the oldest finished one goes"); assert.ok(c.has("b") && c.has("c"))
})

test("pictures drawn this frame are never dropped: more than max faces on screen sit over the cap, and loads stop", () => {
  const c = faceCache({ max: 3 })
  const onScreen = ["a", "b", "c", "d", "e"]
  let loads = 0
  // The draw: start a frame, draw every face, load (here: land at once) any picture that isn't there.
  const frame = faces => { c.frame(); for (const k of faces) if (c.get(k) === undefined) { loads++; c.set(k, k.toUpperCase()) } }
  frame(onScreen)
  assert.equal(loads, 5)
  for (let i = 0; i < 20; i++) frame(onScreen)
  assert.equal(loads, 5, "no picture reloads while the same faces show")
  assert.equal(c.size, 5, "over the cap while they're on screen")
  // A new face comes on screen while the five are only being drawn (get): its load drops none of them.
  frame([...onScreen, "g"])
  assert.equal(loads, 6)
  for (const k of onScreen) assert.ok(c.has(k), k)
  frame([...onScreen, "g"])
  assert.equal(loads, 6, "and nothing reloads after")
  // They leave the screen: the next picture loaded brings the cache back down to the cap.
  frame(["f"])
  assert.equal(c.size, 3)
  assert.ok(c.has("f"))
})

test("a picture landing between frames doesn't drop one drawn in the last frame", () => {
  const c = faceCache({ max: 2 })
  c.frame(); c.set("a", "A"); c.set("b", "B"); c.get("a"); c.get("b")
  c.set("c", "C") // onload, before the next frame
  assert.ok(c.has("a") && c.has("b") && c.has("c"))
  c.frame(); c.get("c"); c.set("d", "D")
  assert.ok(!c.has("a") && !c.has("b"), "once not drawn, the old ones go")
})
