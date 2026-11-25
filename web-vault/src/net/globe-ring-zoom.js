// The WoT tab's Hop 3, Hop 4 and Hop 5 layers zoom your own globe out to that far ring: the inner globe shrinks and
// fades in place, nested in the middle, and the picked ring grows round it to fill the frame (Logen 2026-11-24/25).
// The web twin of Apple Models/GlobeRingZoom.swift (PR 2526) and Android data/model/GlobeRingZoom.kt.
//
// `level` is a continuous zoom: 0 is your circle (Everyone … Further out), 1 is Hop 3, 2 is Hop 4, 3 is Hop 5. The
// globe eases it from pick to pick, so every value between is drawn and it animates both ways. Pure.
import { FIRST_HOP } from "./trust-map-outer.js"

/** A ring's radius against the inner globe's outline at level 0, for the first far hop; each hop after it `STEP` out. */
export const FIRST = 1.72, STEP = 0.26
/** The deepest level: Hop 5. */
export const MAX_LEVEL = 3
/** How big the inner globe is drawn at each whole level. */
export const INNER_SCALES = [1, 0.36, 0.25, 0.18]
/** How strongly the inner globe is drawn at each whole level: faded, never gone. */
export const INNER_ALPHAS = [1, 0.6, 0.5, 0.42]
/** The picked ring's radius as a share of half the frame's short side. */
export const FIT = 0.84
/** Rings inside the picked one are drawn this strongly; rings past it, round its sphere, this strongly. */
export const INSIDE_ALPHA = 0.6, PAST_ALPHA = 0.8
/** What is nested inside the picked ring shrinks in place by this at each whole level, on top of INNER_SCALES. */
export const NEST_SCALES = [1, 0.8, 0.74, 0.68]
/** How fast the level eases toward the picked hop's (per second): about a second each way, slowing into the ring. */
export const EASE = 4.5

function bracket(level) {
  const z = Math.min(MAX_LEVEL, Math.max(0, Number.isFinite(level) ? level : 0))
  const lo = Math.floor(z)
  return [lo, Math.min(MAX_LEVEL, lo + 1), z - lo]
}
const lerp = (table, level) => { const [lo, hi, t] = bracket(level); return table[lo] + (table[hi] - table[lo]) * t }
const eased = (f, level) => { const [lo, hi, t] = bracket(level); const a = f(lo), b = f(hi); return a + (b - a) * t }

/** The zoom level a hop layer asks for; null (your circle) is 0. */
export const levelFor = hop => (hop == null ? 0 : Math.min(MAX_LEVEL, Math.max(1, hop - FIRST_HOP + 1)))

export const innerScale = level => lerp(INNER_SCALES, level)
export const innerAlpha = level => lerp(INNER_ALPHAS, level)

const insideWhole = (hop, whole) => (whole > 0 && hop < FIRST_HOP + whole - 1 ? 1 : 0)
/** How much `hop`'s ring is nested inside the picked one (0 to 1): the inner globe (hop 2 and in) once any hop is
 *  picked, a far ring once a hop past it is. */
export const inside = (hop, level) => eased(w => insideWhole(hop, w), level)
/** How much smaller `hop`'s ring is drawn at `level`, round the frame's middle: 1 unless it is nested. */
export const nest = (hop, level) => 1 - inside(hop, level) * (1 - lerp(NEST_SCALES, level))

const emphasisWhole = (hop, whole) => (whole > 0 && hop === FIRST_HOP + whole - 1 ? 1 : 0)
/** How much `hop`'s ring is the picked one (0 to 1). */
export const emphasis = (hop, level) => eased(w => emphasisWhole(hop, w), level)
/** How much `hop`'s ring is drawn as its own sphere (0 to 1) rather than a flat ring: once picked, and still while
 *  nested inside a later pick. Your circle draws every ring flat. */
export const sphere = (hop, level) => Math.min(1, emphasis(hop, level) + inside(hop, level))

function visibilityWhole(hop, whole) {
  if (whole <= 0) return 1
  const picked = FIRST_HOP + whole - 1
  return hop === picked ? 1 : hop < picked ? INSIDE_ALPHA : PAST_ALPHA
}
/** How strongly `hop`'s ring is drawn at `level` (0 to 1). */
export const visibility = (hop, level) => eased(w => visibilityWhole(hop, w), level)

function radiusWhole(hop, whole, outline, half, grow) {
  const outward = hop - FIRST_HOP
  if (whole <= 0) return outline * (FIRST + STEP * outward)
  // The inner globe at the shrunk outline, the picked ring at the fit, the rings between evenly spaced.
  const inner = outline * INNER_SCALES[whole], fitted = FIT * half * grow
  // Rings past the picked one stay round its sphere, spaced as at your circle (Logen 2026-11-25).
  const past = hop - (FIRST_HOP + whole - 1)
  if (past > 0) return fitted * (1 + STEP / FIRST * past)
  return inner + (fitted - inner) / whole * (outward + 1)
}
/** A ring's radius on screen. `outline` is the inner globe's outline unzoomed, `half` half the frame's short side,
 *  `grow` how far a pinch has zoomed in, so the picked sphere grows with the globe nested in it. */
export const radius = (hop, level, outline, half, grow = 1) => eased(w => radiusWhole(hop, w, outline, half, grow), level)

/** The inner globe's outline on screen at `level`: where hop 3's links land. */
export const innerOutline = (level, outline) => outline * innerScale(level)

/** The inner globe's draw scale round the frame's middle at `level`: it stays centred, never drops. */
export const innerShrink = level => innerScale(level) * nest(FIRST_HOP - 1, level)

/** One frame of easing `level` toward `target`, `dt` seconds on. Reduced motion jumps. */
export function easeLevel(level, target, dt, reduceMotion = false) {
  if (level === target) return level
  if (reduceMotion) return target
  const next = level + (target - level) * (1 - Math.exp(-dt * EASE))
  return Math.abs(target - next) < 0.002 ? target : next
}

/** A ring's centre (the frame's middle) and radius at `level`, shrunk when nested inside the picked one. `base` is the
 *  inner globe's outline on screen now. hop < FIRST_HOP is the inner globe. */
export function place(hop, level, base, width, height, grow = 1) {
  const half = Math.min(width, height) / 2
  const r = hop < FIRST_HOP ? innerOutline(level, base) : radius(hop, level, base, half, grow)
  return { x: width / 2, y: height / 2, r: r * nest(hop, level) }
}
