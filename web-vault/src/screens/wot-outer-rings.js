// Draws the globe's far rings (net/trust-map-outer.js) behind the stars, on your own globe only: one circle per hop
// past your circle, a dot on it for each of its best-ranked people, fainter the further out, and its hop count where
// the ring crosses the top. Faint and dashed, with no dots, when there is no rank. They sit round the middle and grow
// with the camera's zoom, so they stay outside the globe. A Hop layer zooms out to its ring (net/globe-ring-zoom.js):
// the picked ring grows to fill the frame and the inner globe shrinks in place inside it. Once the hop sphere draws the
// picked ring (globe-hop-sphere.js) the flat circle fades out as `sphere` comes in.
// The web twin of Apple Views/TrustWeb/GlobeOuterRings.swift `draw` (PR 2526).
import { outline } from "../net/wot-globe.js"
import { isFaint, fade, chipText } from "../net/trust-map-outer.js"
import { hazeHash } from "../net/globe-haze-field.js"
import { visibility, emphasis, inside, sphere, place } from "../net/globe-ring-zoom.js"

/** Colours (GlobeInk night): the haze's lavender for the circles, a ring star's blue-white for the dots. */
const HAZE = "158 140 230", DOT = "184 209 255", LABEL = "255 255 255"
/** The label stays clear of the WoT tab's top bar. */
const LABEL_TOP = 96

/** The inner globe's outline on screen now (the follows' sphere, radius 1). */
export const baseOutline = (cam, w, h) => outline(1, cam, w, h)
/** How far a pinch has zoomed the nested view in: the outline now against at zoom 1, so the picked ring and everything
 *  nested in it grow together (Logen 2026-11-25). */
export function pinchGrow(cam, w, h) {
  const at1 = outline(1, { ...cam, zoom: 1 }, w, h), now = baseOutline(cam, w, h)
  return Number.isFinite(at1) && Number.isFinite(now) && at1 > 0 ? now / at1 : 1
}

/** The picked ring comes up to full strength, whatever its hop. */
export const strength = (hop, picked) => fade(hop) + (1 - fade(hop)) * picked

/** Up and to the right on the ring where it is still on screen: the top of the circle when it fits, else where it
 *  crosses the right edge. null when it is off the top. */
export function labelPoint(r, x, y, w) {
  const dx = Math.min(r * 0.5, w / 2 - 14)
  if (!(dx > 0) || !(r > dx)) return null
  const ly = y - Math.sqrt(r * r - dx * dx) - 3
  return ly > LABEL_TOP ? { x: x + dx, y: ly } : null
}

/** Draws the flat rings on `g` (2D context, points). `level` is the eased hop zoom; `spheres`: the hop sphere draws the
 *  picked ring (globe-hop-sphere.js), so its flat circle fades out. Without it the picked ring stays a circle at its fit. */
export function drawFlatRings(g, outer, { cam, w, h, level = 0, spheres = false }) {
  if (!outer?.rings.length) return
  const base = baseOutline(cam, w, h)
  if (!Number.isFinite(base)) return
  const grow = pinchGrow(cam, w, h), faint = isFaint(outer)
  for (const ring of outer.rings) {
    const shown = visibility(ring.hop, level)
    if (shown <= 0.01) continue
    const picked = emphasis(ring.hop, level)
    const flat = faint ? 1 : 1 - (spheres ? sphere(ring.hop, level) : 0)
    const { x, y, r } = place(ring.hop, level, base, w, h, grow)
    const f = (faint ? 1 : strength(ring.hop, picked)) * shown
    if (flat > 0.01) {
      g.beginPath(); g.arc(x, y, r, 0, 2 * Math.PI)
      g.setLineDash(faint ? [3, 6] : [])
      g.lineWidth = faint ? 0.8 : 1.1
      g.strokeStyle = `rgb(${HAZE} / ${(faint ? 0.10 : 0.28 * Math.max(f, 0.5 * shown)) * flat})`
      g.stroke()
      g.setLineDash([])
      if (!faint && ring.top.length) {
        g.beginPath()
        for (const key of ring.top) {
          const a = hazeHash(key).angle, px = x + r * Math.cos(a), py = y + r * Math.sin(a)
          g.moveTo(px + 1.6, py); g.arc(px, py, 1.6, 0, 2 * Math.PI)
        }
        g.fillStyle = `rgb(${DOT} / ${0.75 * f * flat})`; g.fill()
      }
    }
    // A ring nested inside a later pick loses its label.
    const nested = inside(ring.hop, level), at = nested < 0.99 ? labelPoint(r, x, y, w) : null
    if (at) {
      g.font = `600 ${10 + 2 * picked}px -apple-system, BlinkMacSystemFont, system-ui, sans-serif`
      g.textAlign = "right"; g.textBaseline = "bottom"
      g.fillStyle = `rgb(${LABEL} / ${(faint ? 0.35 : 0.7 * Math.max(f, 0.5)) * shown * (1 - nested)})`
      g.fillText(faint ? `${ring.hop} hops` : chipText(ring), at.x, at.y)
    }
  }
}

