// A picked hop's sphere: where its people sit (net/globe-sphere-field.js, pinned to the Swift GlobeSphereField's own
// output at tory/hop-sphere 221855c0f) and the sphere's drawing, taps and points (screens/globe-hop-sphere.js) against a
// recording 2D context. Made-up keys.
import test from "node:test"
import assert from "node:assert/strict"
import { points, project, pole, turn, EYE } from "../src/net/globe-sphere-field.js"
import { HopSpheres, MAX_FACES } from "../src/screens/globe-hop-sphere.js"
import { newCamera, qMatrix, IDENTITY } from "../src/net/wot-globe.js"
import { levelFor } from "../src/net/globe-ring-zoom.js"

const near = (a, b, why, eps = 1e-9) => assert.ok(Math.abs(a - b) <= eps, `${why ?? ""} ${a} vs ${b}`)
const KEYS = ["0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b", "3030303030303030303030303030303030303030303030303030303030303030", "5555555555555555555555555555555555555555555555555555555555555555", "7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a", "9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f", "c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4c4", "e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9", "ff00aa11bb22cc33dd44ee55ff6600aa11bb22cc33dd44ee55ff6600aa11bb22", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", ]
const SWIFT_P = [[0.659718781859, -0.557161704237, 0.504323273501], [-0.075348044390, 0.198408668376, 0.977218845766], [-0.157115305490, -0.987545171609, -0.008325551774], [0.747748900817, 0.565477687412, 0.348003687288], [-0.952975608866, -0.159841079651, 0.257465178543], [0.742227778325, -0.157058959681, -0.651483237134], [-0.393342164105, 0.904819704880, 0.163043686166], [-0.716007888875, -0.186168779588, -0.672810440299], [0.165845681071, 0.552952834036, -0.816540490975], ]
const SWIFT_J = [[0.740356224303, 0.625263592636, 1.174164218293, 0.752161636750], [-0.101062434842, -0.266120551398, 1.403345900251, 0.988609422883], [-0.149799161655, 0.941559693004, 0.997557289746, 0.495837224113], [0.796166202686, -0.602092791576, 1.114024937002, 0.674001843644], [-0.985447848310, 0.165287596606, 1.081929141019, 0.628732589272], [0.595326365498, 0.125973915779, 0.839198831884, 0.174258381433], [-0.394880441691, -0.908358262396, 1.050369442884, 0.581521843083], [-0.571288614828, 0.148540408378, 0.834804381357, 0.163594779851], [0.127814418967, -0.426151255445, 0.806348239102, 0.091729754513], ]
const SWIFT_Q = [[-0.203976814281, 0.409522792380, 0.889204443172], [0.831848162189, 0.173274722041, -0.527261325876], [-0.735637332467, -0.595887372134, -0.322111711698], ]

test("the points are the Swift ones", () => {
  const ps = points(KEYS, [0.3, -0.5, 0.8])
  ps.forEach((p, i) => p.forEach((v, k) => near(v, SWIFT_P[i][k], `point ${i}`)))
  ps.forEach((p, i) => { const q = project(p); [q.x, q.y, q.scale, q.front].forEach((v, k) => near(v, SWIFT_J[i][k], `projection ${i}`)) })
  points(KEYS.slice(0, 3), [0, 0.95, 0.3122]).forEach((p, i) => p.forEach((v, k) => near(v, SWIFT_Q[i][k], `helper axis ${i}`)))
})

test("best first from the pole, every point on the unit sphere", () => {
  const ps = points(Array.from({ length: 500 }, (_, i) => i.toString(16).padStart(64, "0")))
  for (const p of ps) near(Math.hypot(...p), 1, "unit", 1e-12)
  assert.ok(ps[0][2] > 0.99, "the best at the front at rest")
  assert.ok(ps.at(-1)[2] < -0.99, "the last at the back")
  const mean = ps.reduce((a, p) => [a[0] + p[0], a[1] + p[1], a[2] + p[2]], [0, 0, 0]).map(v => v / ps.length)
  assert.ok(Math.hypot(...mean) < 0.01, "spread evenly all round")
  assert.deepEqual(points([]), [])
})

test("the pole faces you at rest, and the edge of the sphere lands on its outline", () => {
  assert.deepEqual(pole(IDENTITY).map(v => Math.round(v * 1e9) / 1e9), [0, 0, 1])
  const q = [Math.cos(0.4), 0, Math.sin(0.4), 0] // turned about y
  const pl = pole(q)
  near(turn(qMatrix(q), pl)[2], 1, "the rest turn brings the pole to the front")
  const edge = project([Math.sqrt(1 - 1 / (EYE * EYE)), 0, 1 / EYE])
  near(edge.x, 1, "the silhouette is at radius 1")
  assert.equal(project([0, 0, 1]).front, 1)
  assert.equal(project([0, 0, -1]).front, 0)
})

// A 2D context that records just enough.
const recorder = () => new Proxy({ calls: 0 }, {
  get: (t, k) => k in t ? t[k] : k === "createRadialGradient" ? () => ({ addColorStop() {} }) : () => { t.calls++ },
  set: (t, k, v) => { t[k] = v; return true },
})
const hex = i => i.toString(16).padStart(64, "0")
const ring = (hop, n, haze = 0) => ({ hop, top: Array.from({ length: n }, (_, i) => hex(hop * 1000 + i)), via: new Map(), haze: Array.from({ length: haze }, (_, i) => hex(hop * 100000 + i)) })
const ranked = { source: "ranked", rings: [ring(3, 300, 700), ring(4, 300, 1700), ring(5, 120)] }
const W = 430, H = 860

function drawAt(level, opts = {}) {
  const s = new HopSpheres(), faces = []
  s.draw(recorder(), opts.outer ?? ranked, { cam: newCamera(), w: W, h: H, level, picture: () => true, face: (pk, x, y, r, a) => faces.push({ pk, x, y, r, a }) > 0, focus: opts.focus ?? null })
  return { s, faces }
}

test("nothing at your circle, or with no rank", () => {
  const { s, faces } = drawAt(0)
  assert.equal(faces.length, 0)
  assert.equal(s.hit(W / 2, H / 2), null)
  assert.equal(s.placed.size, 0)
  assert.equal(drawAt(1, { outer: { source: "waiting", rings: ranked.rings } }).s.placed.size, 0)
})

test("Hop 3: a full sphere with faces on its front, none over the nested globe, and taps", () => {
  const { s, faces } = drawAt(levelFor(3))
  assert.deepEqual([...s.placed.keys()], [3], "only the picked sphere at Hop 3")
  assert.ok(faces.length > 20 && faces.length <= MAX_FACES, `${faces.length} faces`)
  for (const f of faces) assert.equal(s.inHole(f.x, f.y), false, "no face over the nested globe")
  const f = faces.at(-1)
  assert.equal(s.hit(f.x, f.y), f.pk)
  assert.ok(s.inHole(W / 2, H / 2))
  assert.ok(s.direction(ranked.rings[0].top[0]), "the best has a spot on the sphere")
  assert.equal(s.direction(ranked.rings[0].haze[0]), null, "haze is never tapped or turned to")
  const sp = s.screenPoint(ranked.rings[0].top[0])
  assert.ok(sp.front > 0.95, "the best faces you at rest")
  near(sp.x, W / 2, "front and centre (the spiral starts just off the pole)", 15)
})

test("Hop 4 nests ring 3's sphere inside, centred and smaller", () => {
  const { s } = drawAt(levelFor(4))
  assert.deepEqual([...s.placed.keys()].sort(), [3, 4])
  const r3 = s.placed.get(3), r4 = s.placed.get(4)
  assert.ok(r3.r < r4.r * 0.8)
  assert.deepEqual([r3.cx, r3.cy], [r4.cx, r4.cy])
  assert.ok(s.screenPoint(ranked.rings[0].top[5], 3), "a path can find someone on the nested sphere")
  assert.equal(s.screenPoint(ranked.rings[0].top[5], 4), null)
})

test("the card's person keeps a face even where the order would drop them", () => {
  const target = ranked.rings[0].top[200]
  const { s, faces } = drawAt(levelFor(3), { focus: target })
  const at = s.screenPoint(target, 3)
  if (at.front >= 0.45) assert.ok(faces.some(f => f.pk === target), "focus seated when on the front")
})
