// The globe's star pass (src/screens/wot-globe-stars.js) allocates nothing per star, but must draw exactly what the
// old pass drew: the same points as projector(), the same dotLight bands, and the same fills in the same order with
// the same arcs. The old pass is kept here as the reference.
import test from "node:test"
import assert from "node:assert/strict"
import { projector, dotLight, qAxis, SIZE, STAR, starAlpha, onScreen } from "../src/net/wot-globe.js"
import { lightBand, pointProjector, StarBands } from "../src/screens/wot-globe-stars.js"

let seed = 7
const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
const cams = () => [
  { q: [1, 0, 0, 0], zoom: 1 },
  { q: qAxis(1.1, [0.3, 1, 0.2]), zoom: 0.8 },
  { q: qAxis(-2.4, [1, -0.4, 0.7]), zoom: 2.4 },
  { q: qAxis(0.6, [0, 0, 1]), zoom: 1.7 },
]
const sphere = r => { const t = rnd() * 2 * Math.PI, u = rnd() * 2 - 1, s = Math.sqrt(1 - u * u); return [r * s * Math.cos(t), r * s * Math.sin(t), r * u] }

test("pointProjector gives projector's point, and false where it gives null", () => {
  for (const cam of cams()) {
    const old = projector(cam, 430, 700), put = pointProjector(cam, 430, 700), into = {}
    for (let i = 0; i < 500; i++) {
      const xyz = sphere([1, 1.3, 1.62, 3.9][i % 4])
      const p = old(xyz), ok = put(xyz, into)
      assert.equal(ok, !!p)
      if (p) for (const f of ["x", "y", "depth", "scale"]) assert.ok(Math.abs(p[f] - into[f]) < 1e-9, f)
    }
  }
})

test("lightBand is the old band of dotLight(depth)", () => {
  for (let d = -2; d <= 2; d += 0.001) assert.equal(lightBand(d), Math.min(3, Math.floor((dotLight(d) - 0.35) / 0.65 * 4)), String(d))
})

const recorder = () => {
  const ops = []
  return { ops, beginPath: () => ops.push(["begin"]), moveTo: (x, y) => ops.push(["move", x, y]), arc: (x, y, r) => ops.push(["arc", x, y, r]),
    fill: () => ops.push(["fill"]), set fillStyle(v) { ops.push(["style", v]) } }
}
const style = (kind, weight, b) => { const star = STAR[kind]; return `rgb(${star[0]} ${star[1]} ${star[2]} / ${Math.min(1, starAlpha(star, 0.35 + 0.65 * (b + 0.5) / 4) * weight)})` }

test("StarBands draws what the old string-keyed bands drew, in the same order", () => {
  const layers = ["further", "extended", "follow"], weights = [1, 0.35, 0.08, 0.028]
  const nodes = Array.from({ length: 3000 }, () => { const layer = layers[Math.floor(rnd() * 3)]; return { layer, w: weights[Math.floor(rnd() * 4)], p: sphere({ further: 1.62, extended: 1.3, follow: 1 }[layer]) } })
  const bands = new StarBands()
  for (const cam of cams()) for (const [w, h] of [[430, 700], [1280, 800]]) {
    // Old: a projected object per star, a "kind|weight|band" key, a Map in first-use order, key.split on the way out.
    const oldG = recorder(), project = projector(cam, w, h), zoomed = Math.min(cam.zoom, 1.8), map = new Map()
    for (const n of nodes) {
      const p = project(n.p)
      if (!p || !onScreen(p.x, p.y, w, h)) continue
      const kind = n.layer === "follow" ? "ring" : n.layer
      const key = `${kind}|${n.w}|${Math.min(3, Math.floor((dotLight(p.depth) - 0.35) / 0.65 * 4))}`
      const list = map.get(key); if (list) list.push(p); else map.set(key, [p])
    }
    for (const [key, list] of map) {
      const [kind, weight, b] = key.split("|"), s0 = SIZE[kind]
      oldG.beginPath()
      for (const p of list) { const s = s0 * p.scale * zoomed; oldG.moveTo(p.x + s, p.y); oldG.arc(p.x, p.y, s, 0, 2 * Math.PI) }
      oldG.fillStyle = style(kind, +weight, +b); oldG.fill()
    }
    // New, with the same StarBands reused across every camera, as the frames reuse it.
    const newG = recorder(), put = pointProjector(cam, w, h), into = {}
    bands.reset()
    for (const n of nodes) {
      if (!put(n.p, into) || !onScreen(into.x, into.y, w, h)) continue
      const kind = n.layer === "follow" ? "ring" : n.layer
      bands.add(kind, n.w, lightBand(into.depth), into.x, into.y, SIZE[kind] * into.scale * zoomed)
    }
    bands.draw(newG, ({ kind, weight, band }) => style(kind, weight, band))
    assert.ok(oldG.ops.length > 100)
    assert.equal(newG.ops.length, oldG.ops.length)
    for (let i = 0; i < oldG.ops.length; i++) {
      const a = oldG.ops[i], b = newG.ops[i]
      assert.equal(b[0], a[0], `op ${i}`)
      for (let j = 1; j < a.length; j++) typeof a[j] === "number" ? assert.ok(Math.abs(a[j] - b[j]) < 1e-9, `op ${i} ${a[0]}`) : assert.equal(b[j], a[j], `op ${i}`)
    }
  }
})
