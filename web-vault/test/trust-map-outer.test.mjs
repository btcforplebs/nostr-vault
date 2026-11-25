// The globe's far rings from a desktop Vault's rank (net/trust-map-outer.js), the same cases as Apple's
// TrustMapOuterTests and GlobeHazeTests (PR 2526). Made-up keys.
import test from "node:test"
import assert from "node:assert/strict"
import { parse } from "../src/net/trust-rank-copy.js"
import { makeOuter, unlocks, shownCount, fade, desktopPaired, chipText, countText, isFaint, ringOf, FOUND_LABEL, WAITING_LABEL, PAIR_LINE, LOCKED_LINE } from "../src/net/trust-map-outer.js"

const pk = c => c.repeat(64)
const hexOf = i => i.toString(16).padStart(64, "0")
const ME = pk("a")

// people: b hop 1, c hop 2, d hop 3 at 70, e hop 3 at 80. globe: ring 3 top e 80, d 70, f 12 (under the floor, only in
// globe); ring 4 top 0 at 20; ring 5 top 1 at 5; then link c (hop 2).
function makeCopy() {
  const rows = [["b", 100, 1], ["c", 80, 2], ["d", 70, 3], ["e", 80, 3]].map(([c, s, h]) => [pk(c), s, h])
  const globe = [["e", 80, 3, "c"], ["d", 70, 3, "c"], ["f", 12, 3, "c"], ["0", 20, 4, "e"], ["1", 5, 5, "0"], ["c", 80, 2, "b"]]
    .map(([c, s, h, v]) => [pk(c), s, h, pk(v)])
  return parse({ account: ME, builtAt: 1795300000, version: 2, maxHop: 6, people: rows, globe, viewBar: 55, floor: 45 }, ME)
}

test("ranked rings are the globe list's top per hop, with no bar", () => {
  const outer = makeOuter(makeCopy(), true)
  assert.equal(outer.source, "ranked")
  assert.equal(isFaint(outer), false)
  assert.deepEqual(outer.rings.map(r => r.hop), [3, 4, 5], "hop-2 link rows are not a ring")
  assert.deepEqual(outer.rings[0].top, [pk("e"), pk("d"), pk("f")], "file order, f at 12 is in: no bar")
  assert.deepEqual(outer.rings[2].top, [pk("1")])
  assert.equal(chipText(outer.rings[0]), "3 hops")
  assert.equal(countText(outer.rings[2]), "The 1 best-scored person in this ring, whatever their score.")
})

test("rings keep each person's link one ring in", () => {
  const outer = makeOuter(makeCopy(), true)
  assert.equal(outer.rings[0].via.get(pk("e")), pk("c"))
  assert.equal(outer.rings[1].via.get(pk("0")), pk("e"))
  assert.deepEqual([...outer.rings[2].via], [[pk("1"), pk("0")]])
})

test("hops unlock only with a ranked ring", () => {
  const ranked = makeOuter(makeCopy(), true)
  assert.ok(unlocks(ranked, 3))
  assert.ok(unlocks(ranked, 5))
  const waiting = makeOuter(null, true)
  assert.equal(waiting.rings.length, 3)
  assert.equal(unlocks(waiting, 3), false)
  assert.equal(unlocks(makeOuter(null, false), 4), false)
  const partial = { source: "ranked", rings: [{ hop: 3, top: [pk("e")], via: new Map(), haze: [] }] }
  assert.ok(unlocks(partial, 3))
  assert.equal(unlocks(partial, 4), false, "a rank with nobody out at a hop leaves it greyed")
})

test("only a ring's first 300 rows are its top; later rows are links", () => {
  const hex = Array.from({ length: 301 }, (_, i) => hexOf(i + 1)), link = pk("c")
  const globe = [...hex.map((h, i) => [h, 90 - i / 10, 3, link]), [link, 80, 2, pk("b")]]
  const copy = parse({ account: ME, builtAt: 1, version: 2, maxHop: 6, people: [[pk("b"), 100, 1]], globe }, ME)
  const ring = makeOuter(copy, true).rings[0]
  assert.equal(ring.top.length, 300)
  assert.equal(ring.top[0], hex[0])
  assert.equal(ring.top.includes(hex[300]), false, "row 301 of a hop is a chain link, not on the ring")
})

test("a zero row is a link, even in a ring under 300", () => {
  const link = pk("c")
  const globe = [[pk("d"), 40, 3, link], [pk("e"), 30, 4, pk("9")], [pk("9"), 0, 3, link], [link, 80, 2, pk("b")]]
  const copy = parse({ account: ME, builtAt: 1, version: 2, maxHop: 6, people: [[pk("b"), 100, 1]], globe }, ME)
  const outer = makeOuter(copy, true)
  assert.deepEqual(outer.rings[0].top, [pk("d")], "9 shows 0: a link to e, not a dot")
})

test("fades per hop", () => {
  assert.equal(fade(3), 1)
  assert.equal(fade(4), 0.6)
  assert.equal(fade(5), 0.35)
})

test("a copy with no globe list draws no rings", () => {
  const copy = parse({ account: ME, builtAt: 1, version: 2, maxHop: 4, people: [[pk("d"), 90, 3]] }, ME)
  assert.ok(copy, "an older engine's file still reads")
  const outer = makeOuter(copy, true)
  assert.equal(outer.source, "ranked")
  assert.deepEqual(outer.rings, [], "rings come from the globe list only, not from people")
})

test("a blocked person is left out", () => {
  const outer = makeOuter(makeCopy(), true, new Set([pk("e")]))
  assert.deepEqual(outer.rings[0].top, [pk("d"), pk("f")])
  assert.equal(outer.rings[1].via.size, 0, "a link to someone blocked is dropped")
})

test("a rank copy counts even with no desktop in the device list", () => {
  assert.equal(makeOuter(makeCopy(), false).source, "ranked")
})

test("no rank draws faint rings, and invites only without a desktop Vault", () => {
  const invite = makeOuter(null, false)
  assert.equal(invite.source, "invite")
  assert.ok(isFaint(invite))
  assert.deepEqual(invite.rings.map(r => r.hop), [3, 4, 5])
  assert.ok(invite.rings.every(r => r.top.length === 0))
  assert.equal(makeOuter(null, true).source, "waiting")
})

test("only a Mac (or a box, which pairs as one) counts as a desktop Vault", () => {
  assert.equal(desktopPaired([{ role: "phone" }, { role: "homeVault" }, { role: null }]), false)
  assert.equal(desktopPaired([{ role: "phone" }, { role: "mac" }]), true)
  assert.equal(desktopPaired(undefined), false)
})

// GlobeHazeTests: globe ring 3 top 1, 2; ring 4 top 3 (via 1).
function hazeCopy(haze) {
  const globe = [[hexOf(1), 80, 3, hexOf(9)], [hexOf(2), 70, 3, hexOf(9)], [hexOf(3), 20, 4, hexOf(1)]]
  return parse({ account: ME, builtAt: 1795300000, version: 2, maxHop: 6, people: [[hexOf(9), 100, 1]], globe, haze }, ME)
}
const rows = (from, n) => Array.from({ length: n }, (_, i) => [hexOf(from + i), 10])

test("rings carry their haze, less blocked people", () => {
  const outer = makeOuter(hazeCopy({ 3: rows(100, 3), 4: rows(200, 2) }), true, new Set([hexOf(101)]))
  assert.deepEqual(ringOf(outer, 3).haze, [hexOf(100), hexOf(102)])
  assert.deepEqual(ringOf(outer, 4).haze, [hexOf(200), hexOf(201)])
  assert.equal(ringOf(outer, 3).top.length, 2, "the top is the tappable people only")
  assert.equal(ringOf(outer, 5), null)
})

test("the picker's count is top plus haze, or none without a haze (Logen 2026-11-25)", () => {
  const withHaze = makeOuter(hazeCopy({ 3: rows(100, 3) }), true)
  assert.equal(shownCount(ringOf(withHaze, 3)), 5)
  assert.equal(shownCount(ringOf(withHaze, 4)), null, "ring 4 has no haze: its top is a cap, not a count")
  assert.equal(shownCount(null), null)
})

test("the words never say Haven", () => {
  for (const text of [FOUND_LABEL, WAITING_LABEL, PAIR_LINE, LOCKED_LINE]) assert.doesNotMatch(text, /haven/i)
})
