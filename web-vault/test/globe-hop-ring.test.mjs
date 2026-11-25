// The Hop layers' zoom out to a far ring (net/globe-ring-zoom.js), the key hash that places a ring's dots
// (net/globe-haze-field.js) and the picker's Hop 3/4/5 (net/wot-hop-layers.js): the cases of Apple's
// GlobeRingZoomTests and GlobeHazeTests (PR 2526). The hash's expected values are the Swift function's own output.
import test from "node:test"
import assert from "node:assert/strict"
import * as Z from "../src/net/globe-ring-zoom.js"
import { hazeHash } from "../src/net/globe-haze-field.js"
import { HOP_LAYERS, hopOf, globeLayerOf, isLocked, hopCounts } from "../src/net/wot-hop-layers.js"
import { labelPoint, pinchGrow, strength } from "../src/screens/wot-outer-rings.js"
import { newCamera } from "../src/net/wot-globe.js"

const near = (a, b, why, eps = 1e-9) => assert.ok(Math.abs(a - b) <= eps, `${why ?? ""} ${a} vs ${b}`)
const OUTLINE = 150, HALF = 200

// GlobeHazeField.hash, run in Swift (HavenApp/HavenApp/Models/GlobeHazeField.swift at tory/hop-sphere 221855c0f).
const SWIFT_HASH = [
  ["0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", 2.275909344601, 0.104000000000],
  ["3030303030303030303030303030303030303030303030303030303030303030", 1.319468914508, 0.156000000000],
  ["5555555555555555555555555555555555555555555555555555555555555555", 3.043854215478, 0.144000000000],
  ["7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a", 1.270599695452, 0.528000000000],
  ["9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f", 2.994984996422, 0.516000000000],
  ["c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4", 0.425860337487, 0.844000000000],
  ["e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9", 2.150245638457, 0.832000000000],
  ["ff00aa11bb22cc33dd44ee55ff6600aa11bb22cc33dd44ee55ff6600aa11bb22", 4.803146101488, 0.296000000000],
  ["0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 1.766273203018, 0.380000000000],
]
test("the key hash is the Swift one", () => {
  for (const [key, angle, wobble] of SWIFT_HASH) {
    const h = hazeHash(key)
    near(h.angle, angle, key, 1e-11)
    near(h.wobble, wobble, key, 1e-11)
  }
})

test("hops map to levels, your circle to zero", () => {
  assert.equal(Z.levelFor(null), 0)
  assert.equal(Z.levelFor(3), 1)
  assert.equal(Z.levelFor(4), 2)
  assert.equal(Z.levelFor(5), 3)
  assert.equal(Z.levelFor(9), 3)
})

test("level zero is the globe as it was", () => {
  assert.equal(Z.innerScale(0), 1)
  assert.equal(Z.innerAlpha(0), 1)
  assert.equal(Z.innerShrink(0), 1)
  near(Z.radius(3, 0, OUTLINE, HALF), OUTLINE * 1.72)
  near(Z.radius(5, 0, OUTLINE, HALF), OUTLINE * (1.72 + 2 * 0.26))
  for (const hop of [3, 4, 5]) { assert.equal(Z.visibility(hop, 0), 1); assert.equal(Z.emphasis(hop, 0), 0) }
})

test("the picked ring fills the frame and the globe shrinks and fades", () => {
  for (const hop of [3, 4, 5]) {
    const level = Z.levelFor(hop)
    near(Z.radius(hop, level, OUTLINE, HALF), Z.FIT * HALF)
    assert.equal(Z.emphasis(hop, level), 1)
    assert.equal(Z.visibility(hop, level), 1)
    assert.ok(Z.innerScale(level) < 0.5)
    assert.ok(Z.innerAlpha(level) < 1 && Z.innerAlpha(level) > 0, "the globe fades, never goes")
  }
  assert.ok(Z.innerScale(1) > Z.innerScale(3))
})

test("rings inside the picked one close in, evenly spaced", () => {
  const r = hop => Z.radius(hop, 3, OUTLINE, HALF)
  assert.ok(Z.innerOutline(3, OUTLINE) < r(3) && r(3) < r(4) && r(4) < r(5))
  near(r(4) - r(3), r(5) - r(4), "evenly spaced")
  assert.equal(Z.visibility(3, 3), Z.INSIDE_ALPHA)
})

test("rings past the picked one stay round its sphere", () => {
  const r = hop => Z.radius(hop, 1, OUTLINE, HALF)
  assert.equal(Z.visibility(4, 1), Z.PAST_ALPHA)
  assert.equal(Z.visibility(5, 2), Z.PAST_ALPHA)
  assert.ok(r(3) < r(4) && r(4) < r(5) && r(4) < HALF)
  assert.equal(Z.sphere(4, 1), 0, "drawn as a flat ring")
  assert.equal(Z.emphasis(3, 3), 0)
})

test("it eases smoothly between levels, both ways", () => {
  for (const hop of [3, 4, 5]) {
    let last = Z.radius(hop, 0, OUTLINE, HALF)
    for (let i = 1; i <= 300; i++) { const now = Z.radius(hop, i / 100, OUTLINE, HALF); assert.ok(Math.abs(now - last) < 6, `hop ${hop} at ${i / 100}`); last = now }
  }
  near(Z.innerScale(0.5), (1 + Z.INNER_SCALES[1]) / 2)
  assert.equal(Z.innerScale(NaN), 1)
  assert.equal(Z.innerScale(7), Z.INNER_SCALES[3])
})

test("rings inside the picked one nest centred and shrink, like an onion", () => {
  assert.equal(Z.nest(2, 0), 1)
  for (const hop of [3, 4, 5]) {
    const level = Z.levelFor(hop)
    assert.equal(Z.nest(hop, level), 1, "the picked ring keeps its size")
    let outside = Z.radius(hop, level, 0.5 * HALF, HALF)
    for (let inner = hop - 1; inner >= 2; inner--) {
      const scale = Z.nest(inner, level)
      assert.ok(scale < 0.85, `hop ${inner} shrinks at Hop ${hop}`)
      const r = (inner < 3 ? Z.innerOutline(level, 0.5 * HALF) : Z.radius(inner, level, 0.5 * HALF, HALF)) * scale
      assert.ok(r < outside, `hop ${inner} at Hop ${hop}`)
      outside = r
    }
  }
  let last = Z.nest(2, 0)
  for (let i = 1; i <= 300; i++) { const n = Z.nest(2, i / 100); assert.ok(Math.abs(n - last) < 0.02); last = n }
  near(Z.innerShrink(1.5), Z.innerScale(1.5) * Z.nest(2, 1.5))
  const p = Z.place(2, 2, OUTLINE, 400, 800)
  assert.deepEqual([p.x, p.y], [200, 400], "stays centred, never drops")
})

test("the level eases toward the pick and lands on it", () => {
  let level = 0
  for (let i = 0; i < 400 && level !== 2; i++) level = Z.easeLevel(level, 2, 1 / 60)
  assert.equal(level, 2)
  assert.equal(Z.easeLevel(0.3, 1, 1 / 60, true), 1, "reduced motion jumps")
  assert.ok(Z.easeLevel(0, 1, 1 / 60) < 0.1, "about a second each way")
})

test("a pinch grows the nested view with the inner globe", () => {
  const cam = newCamera()
  near(pinchGrow(cam, 390, 700), 1)
  assert.ok(pinchGrow({ ...cam, zoom: 1.5 }, 390, 700) > 1.4)
  assert.ok(pinchGrow({ ...cam, zoom: 0.8 }, 390, 700) < 1)
})

test("a ring's label sits on its top, clear of the bar, or not at all", () => {
  assert.deepEqual(labelPoint(100, 200, 400, 400), { x: 250, y: 400 - Math.sqrt(100 * 100 - 50 * 50) - 3 })
  assert.equal(labelPoint(380, 200, 400, 400), null, "off the top")
  assert.equal(strength(5, 1), 1)
  assert.equal(strength(5, 0), 0.35)
})

const ranked = (hops, haze = {}) => ({ source: "ranked", rings: hops.map(hop => ({ hop, top: ["a", "b"], via: new Map(), haze: haze[hop] ?? [] })) })

test("Hop 3/4/5 are greyed until a ranked ring is here", () => {
  assert.deepEqual(HOP_LAYERS.map(([id]) => id), ["hop3", "hop4", "hop5"])
  assert.equal(hopOf("hop4"), 4)
  assert.equal(hopOf("close"), null)
  assert.equal(globeLayerOf("hop3"), "everyone")
  assert.equal(globeLayerOf("close"), "close")
  const waiting = { source: "waiting", rings: [3, 4, 5].map(hop => ({ hop, top: [], via: new Map(), haze: [] })) }
  for (const id of ["hop3", "hop4", "hop5"]) assert.ok(isLocked(waiting, id), id)
  assert.equal(isLocked(waiting, "everyone"), false)
  const some = ranked([3, 4])
  assert.equal(isLocked(some, "hop3"), false)
  assert.ok(isLocked(some, "hop5"), "nobody out at hop 5")
})

test("the picker counts top plus haze, or no number without a haze", () => {
  const outer = ranked([3, 4, 5], { 3: ["c", "d", "e"] })
  assert.deepEqual(hopCounts(outer), { hop3: 5, hop4: null, hop5: null })
  assert.deepEqual(hopCounts({ source: "invite", rings: [] }), { hop3: null, hop4: null, hop5: null })
})
