// The Web of Trust globe's maths (net/wot-globe.js), as the iPhone's TrustMap, GlobeCamera and GlobeEdge: where people
// sit, how the camera spins, zooms and settles, how faces fade at the rim and give up their seats. Made-up keys.
import test from "node:test"
import assert from "node:assert/strict"
import {
  RADIUS, direction, layout, outerFaces, pictured, OUTER_FACES, OUTER_CANDIDATES, newCamera, moving, drag, flick, zoomBy, zoomNow, flyTo, facing, home, step, projector, unit, outline,
  faceShown, faceRadius, dotLight, seatFade, seats, hit, IDENTITY, ZOOM_MIN, ZOOM_MAX, MAX_SPIN, FACE_FULL, FACE_GONE,
} from "../src/net/wot-globe.js"

const hex = (c, i = 0) => (c.repeat(63) + i.toString(16)).slice(-64)
const ME = hex("e")
const W = 390, H = 700
const settle = (c, reduce = false) => { for (let i = 0; i < 2000 && moving(c); i++) c = step(c, 1 / 60, reduce); return c }

test("each person sits on their layer's shell, in the same place every time, you in the middle", () => {
  const web = { me: ME, follows: [hex("1", 1), hex("1", 2)], extended: [hex("2", 3)] }
  const nodes = layout(web, [hex("3", 4)])
  assert.deepEqual(nodes.map(n => n.layer), ["me", "follow", "follow", "extended", "further"])
  assert.deepEqual(nodes[0].p, [0, 0, 0])
  for (const n of nodes.slice(1)) assert.ok(Math.abs(Math.hypot(...n.p) - RADIUS[n.layer]) < 1e-12, n.layer)
  assert.deepEqual(layout(web, [hex("3", 4)]), nodes)
  for (let i = 0; i < 100; i++) assert.ok(Math.abs(Math.hypot(...direction(hex("a", i * 7919))) - 1) < 1e-12)
})

test("faces past your follows: the most linked, taken in turn from both outer shells, added even when capped out", () => {
  const f = Array.from({ length: 12 }, (_, i) => hex("1", i))
  const linkers = new Map([[hex("2", 1), f.slice(0, 12)], [hex("2", 2), f.slice(0, 11)], [hex("3", 1), f.slice(0, 3)], [hex("3", 2), f.slice(0, 1)]])
  // Most linked first, as buildWeb hands them over.
  const web = { me: ME, follows: f, extended: [hex("2", 1), hex("2", 2)], further: [hex("3", 1), hex("3", 2)], linkers,
    layerOf: pk => (pk[0] === "2" ? "extended" : pk[0] === "3" ? "further" : null) }
  assert.deepEqual(outerFaces(web), [hex("2", 1), hex("3", 1), hex("2", 2), hex("3", 2)])
  assert.deepEqual(outerFaces(web, 3), [hex("2", 1), hex("3", 1), hex("2", 2)])
  assert.equal(OUTER_FACES, 36); assert.equal(OUTER_CANDIDATES, 216)
  // Only candidates with a picture become faces, in the same order.
  assert.deepEqual(pictured(outerFaces(web), pk => pk !== hex("3", 1), 2), [hex("2", 1), hex("2", 2)])
  // The further-out list the globe draws is capped; a face left out of it is still drawn, on its shell.
  const nodes = layout(web, [hex("3", 2)], outerFaces(web))
  const byPk = new Map(nodes.map(n => [n.pk, n]))
  assert.ok(byPk.get(hex("3", 1)).face && byPk.get(hex("3", 1)).layer === "further")
  assert.ok(byPk.get(hex("2", 1)).face && !layout(web, [], []).find(n => n.pk === hex("2", 1)).face)
  assert.ok(nodes.filter(n => n.layer === "follow").every(n => n.face))
})

test("a drag turns the front of the globe with the finger", () => {
  const front = [0, 0, RADIUS.follow]
  const p0 = projector(newCamera(), W, H)(front)
  assert.ok(Math.abs(p0.x - W / 2) < 1e-9 && Math.abs(p0.y - H / 2) < 1e-9)
  const right = projector(drag(newCamera(), 40, 0), W, H)(front)
  assert.ok(right.x > p0.x, "dragging right moves the front right")
  const down = projector(drag(newCamera(), 0, 40), W, H)(front)
  assert.ok(down.y > p0.y, "dragging down moves the front down")
})

test("near is bigger and in front; the follows' sphere fits just inside a phone's width", () => {
  const project = projector(newCamera(), W, H)
  const front = project([0, 0, 1]), back = project([0, 0, -1])
  assert.ok(front.scale > 1 && back.scale < 1 && front.depth === 1 && back.depth === -1)
  const o = outline(RADIUS.follow, newCamera(), W, H)
  assert.ok(Math.abs(o - W * 0.96 / 2) < 1e-6, `outline ${o}`)
  assert.ok(unit(800, 600) > 0)
  // Zoomed all the way in, the outer shell's front has passed the lens and isn't drawn.
  assert.equal(projector({ ...newCamera(), zoom: ZOOM_MAX }, W, H)([0, 0, RADIUS.further]), null)
})

test("a flick keeps spinning, slows and stops; its spin is capped; a slow let-go or reduced motion doesn't spin", () => {
  let c = flick(drag(newCamera(), 10, 0), 2000, 0)
  assert.ok(moving(c))
  const q0 = c.q
  c = step(c, 1 / 60)
  assert.notDeepEqual(c.q, q0)
  c = settle(c)
  assert.ok(!moving(c), "it stops")
  assert.ok(Math.hypot(...flick(newCamera(), 1e6, 1e6).spin) <= MAX_SPIN + 1e-9)
  assert.ok(!moving(flick(newCamera(), 200, 0)))
  assert.ok(!moving(flick(newCamera(), 2000, 0, true)))
})

test("the same flick turns the globe the same at 60 and 120 frames a second", () => {
  const a = settle(flick(newCamera(), 1500, 300))
  let b = flick(newCamera(), 1500, 300)
  for (let i = 0; i < 4000 && moving(b); i++) b = step(b, 1 / 120)
  for (let i = 0; i < 4; i++) assert.ok(Math.abs(a.q[i] - b.q[i]) < 1e-3, `${a.q} vs ${b.q}`)
})

test("zoom eases to its target and stays in range; a pinch follows the fingers at once; reduced motion jumps", () => {
  let c = zoomBy(newCamera(), 1.5)
  assert.equal(c.zoom, 1); assert.equal(c.zoomTarget, 1.5)
  c = settle(c)
  assert.equal(c.zoom, 1.5)
  assert.equal(zoomBy(c, 100).zoomTarget, ZOOM_MAX)
  assert.equal(zoomBy(c, 0.0001).zoomTarget, ZOOM_MIN)
  assert.equal(zoomNow(newCamera(), 1.3).zoom, 1.3)
  assert.equal(zoomBy(newCamera(), 1.5, true).zoom, 1.5)
})

test("home glides back to the start at zoom 1; flying to someone brings them to the front", () => {
  let c = settle(zoomBy(drag(newCamera(), 120, -80), 2))
  c = settle(home(c))
  for (let i = 0; i < 4; i++) assert.ok(Math.abs(Math.abs(c.q[i]) - Math.abs(IDENTITY[i])) < 1e-9)
  assert.equal(c.zoom, 1)
  const pk = hex("a", 99)
  c = settle(flyTo(drag(newCamera(), 300, 200), facing(direction(pk))))
  const p = projector(c, W, H)(direction(pk))
  assert.ok(Math.abs(p.depth - 1 / Math.hypot(0.42, 0.30, 1)) < 1e-6, `they face us: depth ${p.depth}`)
  assert.ok(p.x > W / 2 && p.y < H / 2, "a little up and right of the middle, never behind you")
  // Reduced motion cuts straight there.
  assert.ok(!moving(step(flyTo(newCamera(), facing(direction(pk))), 1 / 60, true)))
})

test("faces fade and shrink smoothly toward the rim and round the back, never popping", () => {
  assert.equal(faceShown(FACE_FULL), 1); assert.equal(faceShown(FACE_GONE), 0)
  let prev = 0
  for (let d = -1.6; d <= 1.6; d += 0.01) {
    const s = faceShown(d)
    assert.ok(s >= prev - 1e-12 && s - prev < 0.05, `step at depth ${d}`)
    prev = s
  }
  assert.equal(faceRadius(10, 1), 10); assert.equal(faceRadius(10, 0), 6)
  assert.ok(Math.abs(dotLight(-1.6) - 0.35) < 1e-12 && dotLight(1) === 1)
})

test("a seat fades in and out over a quarter second; reduced motion cuts", () => {
  let f = 0, frames = 0
  while (f !== 1 && frames < 100) { f = seatFade(f, true, 1 / 60); frames++ }
  assert.ok(frames > 5 && frames < 40, `${frames} frames`)
  assert.equal(seatFade(0.5, false, 1 / 60, true), 0)
})

test("seats: the nearer face keeps its seat, overlapping ones give it up, the back gets none", () => {
  const faces = [
    { pk: "near", x: 100, y: 100, depth: 0.9, r: 10 },
    { pk: "behind", x: 105, y: 100, depth: 0.5, r: 10 },
    { pk: "apart", x: 200, y: 100, depth: 0.2, r: 10 },
    { pk: "back", x: 300, y: 300, depth: -0.5, r: 10 },
  ]
  assert.deepEqual([...seats(faces)].sort(), ["apart", "near"])
  // A follow's face leads: it keeps its seat over a nearer face from further out.
  const lead = [{ pk: "stranger", x: 100, y: 100, depth: 0.9, r: 9 }, { pk: "follow", x: 104, y: 100, depth: 0.3, r: 11, lead: true }]
  assert.deepEqual([...seats(lead)], ["follow"])
})

test("a tap picks a showing face before a dot, and nothing round the back", () => {
  const face = { node: { pk: "f" }, x: 100, y: 100, depth: 0.5, r: 12, shown: 1, face: true }
  const dot = { node: { pk: "d" }, x: 104, y: 100, depth: 0.5, face: false }
  const hidden = { node: { pk: "h" }, x: 300, y: 300, depth: 0.5, r: 12, shown: 0.2, face: true }
  const back = { node: { pk: "b" }, x: 400, y: 400, depth: -0.5, face: false }
  assert.equal(hit([dot, face], 104, 100).pk, "f")
  assert.equal(hit([hidden, face, dot, back], 300, 300), null)
  assert.equal(hit([back], 400, 400), null)
  assert.equal(hit([dot], 110, 100).pk, "d")
})

test("a big web: projecting and seating 2,500 follows and 5,000 dots takes a few ms", () => {
  const follows = Array.from({ length: 2500 }, (_, i) => hex("a", i * 15485863))
  const further = Array.from({ length: 5000 }, (_, i) => hex("b", i * 7))
  const nodes = layout({ me: ME, follows, extended: [] }, further)
  const t = performance.now()
  const project = projector(newCamera(), W, H), faces = []
  for (const n of nodes) { const p = project(n.p); if (p && n.layer === "follow") faces.push({ pk: n.pk, x: p.x, y: p.y, depth: p.depth, r: 11 * p.scale }) }
  const seated = seats(faces)
  assert.ok(performance.now() - t < 100, `${performance.now() - t} ms`)
  assert.ok(seated.size > 20 && seated.size < faces.length / 2, `${seated.size} seated of ${faces.length}`)
})
