// The globe's stars, drawn every frame while it moves (WotGlobe.jsx). A big web is thousands of them, so this pass
// allocates nothing per star: projecting writes into one reused point, stars are filed by number (kind x weight x
// brightness band) into reused coordinate lists, and each list is one path and one fill. Same maths as
// net/wot-globe.js projector() and dotLight(); the perf review of 2026-11-18 found the old pass (a new object, a
// template-string Map key and a record per star per frame) at 3 s of script per 10 s of dragging.
import { DISTANCE, qMatrix, unit } from "../net/wot-globe.js"

/** projector(cam, width, height) without the allocation: project(xyz, into) fills `into` ({ x, y, depth, scale }) and
 *  returns false where projector returns null (zoomed in past the shell). */
export function pointProjector(cam, width, height) {
  const m = qMatrix(cam.q), camZ = DISTANCE / cam.zoom, u = unit(width, height), mx = width / 2, my = height / 2
  const [m0, m1, m2, m3, m4, m5, m6, m7, m8] = m
  return (xyz, into) => {
    const x = xyz[0], y = xyz[1], z = xyz[2]
    const vz = m6 * x + m7 * y + m8 * z, gap = camZ - vz
    if (gap < 0.45) return false
    const s = 1 / gap
    into.x = mx + (m0 * x + m1 * y + m2 * z) * s * u
    into.y = my - (m3 * x + m4 * y + m5 * z) * s * u
    into.depth = vz
    into.scale = s * camZ
    return true
  }
}

/** dotLight(depth)'s band, 0..3: the brightness steps stars are filled in. */
export function lightBand(depth) {
  const t = Math.min(1, Math.max(0, (depth + 0.45) / 0.5)), light = 0.35 + 0.65 * t * t * (3 - 2 * t)
  return Math.min(3, Math.floor((light - 0.35) / 0.65 * 4))
}

const KIND = { further: 0, extended: 1, ring: 2, hot: 3 }
export const KINDS = ["further", "extended", "ring", "hot"]

/** Stars filed by kind, weight and band; reused frame to frame. */
export class StarBands {
  weights = [] // the distinct weights seen this frame; a slot's index uses its place here
  slots = [] // slot index -> { kind, weight, band, xy: [x, y, r, ...], n }
  used = [] // slot indexes filled this frame, in first-use order
  reset() {
    for (const i of this.used) this.slots[i].n = 0
    this.used.length = 0
    this.weights.length = 0
  }
  add(kind, weight, band, x, y, r) {
    let w = this.weights.indexOf(weight)
    if (w < 0) { w = this.weights.length; this.weights.push(weight) }
    const i = (w * 4 + KIND[kind]) * 4 + band
    let slot = this.slots[i]
    if (!slot) slot = this.slots[i] = { kind, weight, band, xy: [], n: 0 }
    if (slot.n === 0) { this.used.push(i); slot.kind = kind; slot.weight = weight; slot.band = band }
    const at = slot.n * 3
    slot.xy[at] = x; slot.xy[at + 1] = y; slot.xy[at + 2] = r
    slot.n++
  }
  /** One path and one fill per slot: `style(slot)` gives its fillStyle. */
  draw(g, style) {
    for (const i of this.used) {
      const { xy, n } = this.slots[i]
      g.beginPath()
      for (let j = 0; j < n * 3; j += 3) { const x = xy[j], y = xy[j + 1], r = xy[j + 2]; g.moveTo(x + r, y); g.arc(x, y, r, 0, 2 * Math.PI) }
      g.fillStyle = style(this.slots[i])
      g.fill()
    }
  }
}
