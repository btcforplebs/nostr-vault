// 3D objects: kind 33331, SNO (DECK-0003 "Simple Nostr Objects", by arkin0x, the format SNOcrash.art and ONOSENDAI
// write). Reading and validating the payload is arkin0x's sno-core (src/vendor/sno-core, vendored with his OK): its
// fromPayload performs every check of §1.9 and refuses the whole object when one fails, as §4 says a reader must.
// sno-core answers only "no", and the spec asks a reader to show why, so `rejectReason` names the first §1.9 rule a
// refused payload breaks, in plain words. What a stage draws (`geometry`) comes from the same model: render-frame
// positions, per-vertex colours, faces, per-face colours, and a placeholder cube for each placed part (§1.10: parts
// are not fetched here, which the spec allows).
import { fromPayload, ticksOf, toRender, unpackFaceColors, MODES, MAX_UNIT, TICKS_PER_UNIT } from "../vendor/sno-core/shards.js"
import { resolvePalette } from "../vendor/sno-core/snoPalette.js"

export const SNO_KIND = 33331
/** Above this many faces a card shows the text and "Open to view" rather than drawing (the plan's card limit). */
export const CARD_MAX_FACES = 4000

const tag = (ev, name) => ev?.tags?.find(t => t[0] === name)?.[1]
const isInt = n => Number.isInteger(n)

/** The event's `alt` text (NIP-31), or "". */
export const altText = ev => (typeof tag(ev, "alt") === "string" ? tag(ev, "alt").trim() : "")

/**
 * A kind 33331 event read. -> { ok: true, model, name, alt, vertices, faces, mode } or { ok: false, reason, name, alt }.
 * `name` is the payload's when it has one, else the event's `name` tag, else "".
 */
export function readSno(ev) {
  const alt = altText(ev)
  let raw
  try { raw = JSON.parse(ev?.content ?? "") } catch { return { ok: false, reason: "Its content isn't JSON.", name: tag(ev, "name") ?? "", alt } }
  const name = typeof raw?.name === "string" && raw.name.trim() ? raw.name.trim().slice(0, 64) : tag(ev, "name") ?? ""
  const model = fromPayload(raw, ev?.id ?? "")
  if (!model) return { ok: false, reason: rejectReason(raw), name, alt }
  return { ok: true, model, name: model.name, alt, vertices: model.vertices.length, faces: model.faces.length, mode: model.mode }
}

const triple = (x, ok) => Array.isArray(x) && x.length === 3 && x.every(ok)

/** The first DECK-0003 §1.9 rule a payload fails, in plain words, for the card's grey line. Called only on a payload
 *  sno-core refused, so it always names something; the last line is for a refusal none of these explains. */
export function rejectReason(p) {
  if (!p || typeof p !== "object" || Array.isArray(p)) return "Its content isn't an object."
  if (p.v !== 1 && p.v !== 2) return `It says it is version ${JSON.stringify(p.v ?? null)}; only 1 and 2 exist.`
  if (typeof p.name !== "string" || !p.name.trim()) return "It has no name."
  for (const k of ["ticks", "palette", "facecolors", "up", "spin", "refs", "parts"]) if (p[k] === null) return `Its ${k} is null.`
  if (!Array.isArray(p.vertices) || !Array.isArray(p.colors) || !Array.isArray(p.faces)) return "Its vertices, colors or faces aren't lists."
  if (p.vertices.length !== p.colors.length) return `It has ${p.vertices.length} vertices but ${p.colors.length} colors.`
  if (!MODES.includes(p.mode)) return `Its mode ${JSON.stringify(p.mode)} isn't solid, points or lines.`
  if (!isInt(p.unit) || p.unit < 0 || p.unit > MAX_UNIT) return `Its unit must be a whole number from 0 to ${MAX_UNIT}.`
  const bad = p.vertices.findIndex(v => !triple(v, isInt))
  if (bad >= 0) return `Vertex ${bad + 1} isn't three whole numbers.`
  if (p.ticks !== undefined && !ticksFit(p.ticks, p.vertices.length)) return "Its ticks don't give one remainder (0 to 119) per vertex."
  const n = p.vertices.length
  const face = p.faces.findIndex(f => !triple(f, i => isInt(i) && i >= 0 && i < n) || new Set(f).size !== 3)
  if (face >= 0) return `Face ${face + 1} doesn't name three different vertices of the ${n}.`
  const palette = resolvePalette(p.palette)
  if (!palette) return "Its palette isn't a known name, a palette reference, or 2 to 256 colors."
  const col = p.colors.findIndex(c => (Array.isArray(c) ? !triple(c, x => typeof x === "number") : p.v === 1 || !isInt(c) || c < 0 || c >= palette.length))
  if (col >= 0) return `Color ${col + 1} isn't ${p.v === 1 ? "three numbers" : `a palette index from 0 to ${palette.length - 1}`}.`
  if (p.facecolors !== undefined && !unpackFaceColors(p.facecolors, p.faces.length, palette)) return "Its facecolors don't give one palette color per face."
  if (p.up !== undefined && typeof p.up !== "boolean") return "Its up isn't true or false."
  if (p.spin !== undefined && !(isInt(p.spin) && p.spin >= 0 && p.spin <= 359)) return "Its spin isn't a whole degree from 0 to 359."
  if (p.refs !== undefined || p.parts !== undefined) return "Its refs or parts don't name the objects it places correctly."
  return "It doesn't follow the 3D object format (DECK-0003 §1.9)."
}

function ticksFit(packed, count) {
  if (!Array.isArray(packed)) return false
  let n = 0
  for (const e of packed) {
    if (typeof e === "number") { if (!isInt(e) || e >= 0) return false; n -= e }
    else if (triple(e, t => isInt(t) && t >= 0 && t < TICKS_PER_UNIT)) n++
    else return false
  }
  return n === count
}

/**
 * What a stage draws, in the render frame (sno-core toRender: whole units, right-handed, Z toward the viewer),
 * centred on its bounds. -> { points: [[x,y,z]], colors: [[r,g,b] 0..1], faces: [[a,b,c]], faceColors: [[r,g,b]] | null,
 * mode, radius, placeholders: [[x,y,z]] (one per placed part, where it stands) }
 */
export function geometry(model) {
  const pts = model.vertices.map(v => toRender(ticksOf(v)))
  const parts = (model.parts ?? []).map(p => toRender(p.at ?? p.offset ?? [0, 0, 0]))
  const all = [...pts, ...parts.flatMap(c => cube(c))]
  const min = [0, 1, 2].map(i => Math.min(...all.map(p => p[i]))), max = [0, 1, 2].map(i => Math.max(...all.map(p => p[i])))
  const mid = all.length ? min.map((m, i) => (m + max[i]) / 2) : [0, 0, 0]
  const shift = p => [p[0] - mid[0], p[1] - mid[1], p[2] - mid[2]]
  const points = pts.map(shift)
  const radius = Math.max(0.5, ...all.map(p => Math.hypot(...shift(p))))
  return { points, colors: model.vertices.map(v => v.c), faces: model.faces, faceColors: model.facecolors ?? null, mode: model.mode, radius, placeholders: parts.map(shift) }
}

/** A one-unit cube's corners around `c` (the spec's reference placeholder for a part it doesn't draw). */
export const cube = c => [-0.5, 0.5].flatMap(x => [-0.5, 0.5].flatMap(y => [-0.5, 0.5].map(z => [c[0] + x, c[1] + y, c[2] + z])))
