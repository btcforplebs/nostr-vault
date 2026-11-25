// A hop sphere person's path in to you (net/globe-chain.js, screens/globe-chain-painter.js): the cases of Apple's
// GlobeChainTests (PR 2526), and how the painter finds each link on screen. Made-up keys.
import test from "node:test"
import assert from "node:assert/strict"
import { parse } from "../src/net/trust-rank-copy.js"
import { chainLinks } from "../src/net/globe-chain.js"
import { chainPoints, legShare, drawChain } from "../src/screens/globe-chain-painter.js"

const pk = i => i.toString(16).padStart(64, "0")
const ME = pk(0xa)
// Follow 1; hop 2: 2 (via 1); hop 3: 3 (via 2); hop 4: 4 (via 3), 5 (via 6, unknown).
const copy = parse({ account: ME, builtAt: 1795300000, version: 2, maxHop: 5, people: [[pk(1), 100, 1]], viewBar: 55, floor: 0,
  globe: [[pk(2), 60, 2, pk(1)], [pk(3), 50, 3, pk(2)], [pk(4), 40, 4, pk(3)], [pk(5), 30, 4, pk(6)]] }, ME)

test("hop 4 walks in through every ring to a follow", () => {
  const links = chainLinks(pk(4), copy, new Set([pk(1)]))
  assert.deepEqual(links.map(l => l.key), [pk(4), pk(3), pk(2), pk(1)])
  assert.deepEqual(links.map(l => l.hop), [4, 3, 2, 1])
})

test("an unknown link ends the walk there", () => {
  const links = chainLinks(pk(5), copy, new Set([pk(1)]))
  assert.deepEqual(links.map(l => l.key), [pk(5), pk(6)])
  assert.equal(links.at(-1).hop, null)
})

test("no copy, or not on the globe, is no path", () => {
  assert.deepEqual(chainLinks(pk(4), null, new Set()), [])
  assert.deepEqual(chainLinks(pk(99), copy, new Set()), [])
})

test("a loop in the links ends the walk", () => {
  const loop = parse({ account: ME, builtAt: 1, version: 2, maxHop: 5, people: [], globe: [[pk(3), 50, 3, pk(4)], [pk(4), 40, 4, pk(3)]] }, ME)
  assert.deepEqual(chainLinks(pk(4), loop, new Set()).map(l => l.key), [pk(4), pk(3)])
})

test("each link is found on its layer, and one off screen is skipped", () => {
  const links = chainLinks(pk(4), copy, new Set([pk(1)]))
  const sphere = new Map([[`${pk(4)}@4`, { x: 1, y: 1, front: 1 }], [`${pk(3)}@3`, { x: 2, y: 2, front: 0.5 }]])
  const globe = new Map([[pk(1), { x: 4, y: 4, front: 1 }]]) // pk(2) is not on screen
  const pts = chainPoints(links, (k, hop) => sphere.get(`${k}@${hop}`) ?? null, k => globe.get(k) ?? null)
  assert.deepEqual(pts.map(p => p.x), [1, 2, 4])
  assert.equal(chainPoints(links, () => null, () => ({ x: 0, y: 0, front: 1 })), null, "not on a sphere: no line")
  assert.equal(chainPoints([], () => ({}), () => ({})), null)
})

test("the line draws in leg by leg from them toward you", () => {
  assert.equal(legShare(0, 0.25, 4), 1)
  assert.equal(legShare(1, 0.25, 4), 0)
  assert.equal(legShare(2, 0.625, 4), 0.5)
  let strokes = 0
  const g = new Proxy({}, { get: (t, k) => k in t ? t[k] : k === "stroke" ? () => { strokes++ } : () => {}, set: (t, k, v) => { t[k] = v; return true } })
  drawChain(g, [{ x: 0, y: 0, front: 1 }], 1)
  assert.equal(strokes, 0, "one point is no line")
  drawChain(g, [{ x: 0, y: 0, front: 1 }, { x: 5, y: 0, front: 1 }, { x: 9, y: 0, front: 1 }], 1)
  assert.ok(strokes >= 4, "glow, each leg, the ring")
})
