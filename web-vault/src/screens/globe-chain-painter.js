// Draws a hop sphere person's path in to you (net/globe-chain.js, Logen 2026-11-25): from their face through each
// link's spot on its layer (the nested spheres, then the inner globe) to you in the middle. The points are found again
// every frame, so the line follows the layers as they spin. It draws in from them toward you over DRAW_IN seconds, like
// the inner globe's threads. The web twin of Apple Views/TrustWeb/GlobeChainPainter.swift (PR 2526).

/** How long the line takes to draw in, seconds. */
export const DRAW_IN = 0.6
const ACCENT = "230 115 38", THREAD = "255 168 77"

/**
 * Each link's spot on screen this frame: a far ring's link on its sphere (`sphereAt(pk, hop)`), anyone nearer on the
 * inner globe (`globeAt(pk)`), else on any sphere. A link not on screen is skipped. null when the first link (the
 * tapped person) isn't on a sphere, so the line is drawn only for someone who is. -> [{ x, y, front }] or null
 */
export function chainPoints(chain, sphereAt, globeAt) {
  if (!chain.length || !sphereAt(chain[0].key, chain[0].hop)) return null
  const out = []
  for (const link of chain) {
    const at = link.hop != null && link.hop >= 3 ? sphereAt(link.key, link.hop) : globeAt(link.key) ?? sphereAt(link.key, null)
    if (at) out.push(at)
  }
  return out
}

/** How much of each leg is drawn at `progress` (0..1) along `legs` legs. */
export const legShare = (i, progress, legs) => Math.min(1, Math.max(0, progress * legs - i))

/** `points` ([{ x, y, front }]) run from the tapped person to you; a stretch round the back is drawn fainter. */
export function drawChain(g, points, progress) {
  if (points.length < 2 || !(progress > 0)) return
  const legs = points.length - 1, drawn = []
  for (let i = 0; i < legs; i++) {
    const share = legShare(i, progress, legs)
    if (share <= 0) break
    const a = points[i], b = points[i + 1], end = { x: a.x + (b.x - a.x) * share, y: a.y + (b.y - a.y) * share }
    drawn.push([a, end, (a.front + b.front) / 2])
  }
  // The glow under the line, then the line, then a ring round the person and a bead on each link reached.
  g.save()
  g.lineCap = "round"
  g.filter = "blur(4px)"
  g.beginPath(); for (const [a, e] of drawn) { g.moveTo(a.x, a.y); g.lineTo(e.x, e.y) }
  g.lineWidth = 3; g.strokeStyle = `rgb(${ACCENT} / .55)`; g.stroke()
  g.filter = "none"
  for (const [a, e, front] of drawn) {
    g.beginPath(); g.moveTo(a.x, a.y); g.lineTo(e.x, e.y)
    g.lineWidth = 1.4; g.strokeStyle = `rgb(${THREAD} / ${0.45 + 0.5 * front})`; g.stroke()
  }
  const s = points[0]
  g.beginPath(); g.arc(s.x, s.y, 13, 0, 2 * Math.PI); g.lineWidth = 2; g.strokeStyle = `rgb(${ACCENT} / .9)`; g.stroke()
  for (let i = 1; i < points.length - 1 && i <= progress * legs; i++) {
    g.beginPath(); g.arc(points[i].x, points[i].y, 2.6, 0, 2 * Math.PI); g.fillStyle = `rgb(${ACCENT} / ${0.6 + 0.4 * points[i].front})`; g.fill()
  }
  g.restore()
}
