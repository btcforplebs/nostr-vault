// Draws a picked hop as its own globe (net/globe-sphere-field.js, Logen 2026-11-25): the ring's top 300 as bright stars
// with the best of them on the front as faces you can tap, and its haze as faint dust over the rest of the surface. It
// turns with the inner globe's camera, so one drag spins both. The inner globe stays in the middle, shrunk inside it
// (net/globe-ring-zoom.js), and the sphere's faces keep clear of it so it stays in view and tappable. Picking a hop
// further out nests this sphere in turn, smaller and fainter. The web twin of Apple Views/TrustWeb/GlobeHopSphere.swift
// and GlobeOuterRings.drawSpheres (PR 2526).
//
// One HopSpheres per globe: it keeps each ring's points (worked out once per ring), who held a face last frame (so faces
// don't swap as it turns), and where everything landed last frame, for taps and for a path (screenPoint).
import { qMatrix, seats, smoothstep, FACE_GONE, FACE_FULL, faceRadius, RING_FACES } from "../net/wot-globe.js"
import { points, pole, project, turn } from "../net/globe-sphere-field.js"
import { isFaint, FIRST_HOP } from "../net/trust-map-outer.js"
import { sphere, visibility, emphasis, place } from "../net/globe-ring-zoom.js"
import { baseOutline, pinchGrow, strength } from "./wot-outer-rings.js"

/** A face's radius on the front of a fitted sphere: the inner globe's follow faces' size. */
export const FACE_SIZE = 11
/** As many faces at once as the inner globe shows on its ring, so the sphere reads as the same kind of globe. */
export const MAX_FACES = RING_FACES
/** Faces show over the side facing you and fade toward the rim, where the inner globe's do (as 0-1 front-ness). */
export const FACE_FROM = (1 + FACE_GONE) / 2, FACE_FULL_AT = (1 + FACE_FULL) / 2
/** The nested globe's faces reach past its outline to its outer shell: the hole the picked sphere leaves for it. */
export const HOLE_REACH = 1.1
/** A picked sphere's radius at which faces and dots are drawn their own size; they grow with a pinch. */
const FITTED = 170
/** Brightness steps per kind of dot, so 2,000 dots are a few fills. */
const LEVELS = 16
const HAZE = "158 140 230", STAR = "184 209 255"

export class HopSpheres {
  constructor() { this.built = new Map(); this.seated = new Set(); this.clear() }

  clear() { this.targets = []; this.hole = null; this.placed = new Map(); this.picked = null }

  /** A ring's points, built once per ring and pole. */
  pointsFor(ring, p) {
    const b = this.built.get(ring.hop)
    if (b && b.top === ring.top && b.haze === ring.haze && b.pole === p) return b
    const nb = { top: ring.top, haze: ring.haze, pole: p, keys: [...ring.top, ...ring.haze], points: points([...ring.top, ...ring.haze], p) }
    nb.index = new Map(nb.keys.map((k, i) => [k, i]))
    this.built.set(ring.hop, nb)
    return nb
  }

  /**
   * Draws every hop sphere for this frame on `g`, over the inner globe. `picture(pk)`: whether their picture is in, so
   * only they take a face; `face(pk, x, y, r, alpha)`: draws one (WotGlobe's own, so pictures load and cache the same) and is false while its
   * picture is still loading.
   * `focus`: the trust card's person, who always keeps a seat.
   */
  draw(g, outer, { cam, w, h, level, picture, face, focus = null }) {
    this.clear()
    if (!(level > 0.001) || !outer || isFaint(outer)) return
    const base = baseOutline(cam, w, h)
    if (!Number.isFinite(base)) return
    const grow = pinchGrow(cam, w, h), m = qMatrix(cam.q), p = pole()
    const globe = place(FIRST_HOP - 1, level, base, w, h, grow)
    this.hole = { x: globe.x, y: globe.y, r: globe.r * HOLE_REACH }
    // Inner first, so the picked one is drawn over what is nested in it.
    for (const ring of outer.rings) {
      const shown = visibility(ring.hop, level) * sphere(ring.hop, level)
      if (shown <= 0.01 || !(ring.top.length || ring.haze.length)) continue
      const picked = emphasis(ring.hop, level), at = place(ring.hop, level, base, w, h, grow)
      if (at.r <= 4) continue
      this.drawOne(g, ring, at, shown * strength(ring.hop, picked), picked, m, p, picture, face, focus)
    }
  }

  drawOne(g, ring, { x: cx, y: cy, r }, shown, picked, m, p, picture, face, focus) {
    const b = this.pointsFor(ring, p)
    this.placed.set(ring.hop, { b, cx, cy, r, m })
    if (picked > 0.5) this.picked = b
    const hole = this.hole, clear = (x, y, pad = 0) => !hole || Math.hypot(x - hole.x, y - hole.y) >= hole.r + pad
    // The body: a faint glass ball lit a little up and to the left, and its outline, so it reads as a globe first.
    const body = g.createRadialGradient(cx - r * 0.3, cy - r * 0.35, 0, cx - r * 0.3, cy - r * 0.35, r * 1.2)
    body.addColorStop(0, `rgb(${HAZE} / ${0.14 * shown})`); body.addColorStop(1, `rgb(${HAZE} / ${0.03 * shown})`)
    g.beginPath(); g.arc(cx, cy, r, 0, 2 * Math.PI); g.fillStyle = body; g.fill()
    g.lineWidth = 0.6; g.strokeStyle = `rgb(${HAZE} / ${0.08 * shown})`; g.stroke()

    const buckets = [Array.from({ length: LEVELS + 1 }, () => []), Array.from({ length: LEVELS + 1 }, () => [])]
    const back = 0.55 + 0.45 * picked, zoomed = Math.min(1.8, Math.max(0.7, r / FITTED))
    const faces = [], taps = [], q = {}, top = b.top.length, withFaces = picked > 0.3
    for (let i = 0; i < b.points.length; i++) {
      project(turn(m, b.points[i]), q)
      const x = cx + q.x * r, y = cy + q.y * r, isTop = i < top
      const a = (isTop ? 0.25 + 0.65 * q.front : 0.06 + 0.22 * q.front) * shown * back
      const size = (isTop ? 2.1 : 1.2) * q.scale * zoomed * back
      if (isTop && withFaces && q.front >= FACE_FROM && picture(b.keys[i])) faces.push({ pk: b.keys[i], x, y, r: FACE_SIZE * q.scale * zoomed, depth: q.front, front: q.front, rank: i })
      if (isTop && picked > 0.5 && q.front > 0.55 && clear(x, y)) taps.push({ pk: b.keys[i], x, y, reach: 14 })
      const lv = Math.round(Math.min(1, a) * LEVELS)
      if (lv > 0) buckets[isTop ? 1 : 0][lv].push(x, y, size)
    }
    for (const [kind, colour] of [[0, HAZE], [1, STAR]]) {
      for (let lv = 1; lv <= LEVELS; lv++) {
        const d = buckets[kind][lv]
        if (!d.length) continue
        g.beginPath()
        for (let k = 0; k < d.length; k += 3) { g.moveTo(d[k] + d[k + 2], d[k + 1]); g.arc(d[k], d[k + 1], d[k + 2], 0, 2 * Math.PI) }
        g.fillStyle = `rgb(${colour} / ${lv / LEVELS})`; g.fill()
      }
    }
    if (withFaces && faces.length) {
      // Who fits: those who held a face last frame and the card's person first, then front-most; none over the nested
      // globe. Then the best-ranked of them, up to MAX_FACES.
      const kept = this.seated
      for (const f of faces) f.lead = f.pk === focus || kept.has(f.pk)
      const fit = seats(faces.filter(f => f.pk === focus || clear(f.x, f.y, f.r)))
      const chosen = faces.filter(f => fit.has(f.pk)).sort((a, z) => (z.pk === focus) - (a.pk === focus) || a.rank - z.rank).slice(0, MAX_FACES)
      this.seated = new Set(chosen.map(f => f.pk))
      chosen.sort((a, z) => a.front - z.front) // back to front
      for (const f of chosen) {
        const o = smoothstep(FACE_FROM, FACE_FULL_AT, f.front) * Math.min(1, (picked - 0.3) / 0.5) * shown
        if (o <= 0.01) continue
        // A face whose picture isn't in yet stays its star (and still loads), never a lettered stand-in.
        if (!face(f.pk, f.x, f.y, faceRadius(f.r, o / Math.max(shown, 0.01)), o)) continue
        if (o > 0.5) taps.push({ pk: f.pk, x: f.x, y: f.y, reach: Math.max(24, f.r + 8) })
      }
    } else if (picked > 0.3) this.seated = new Set()
    if (picked > 0.5) this.targets = taps
  }

  /** The face (or front star) of the picked sphere under a tap at (x, y), from the frame last drawn, or null. */
  hit(x, y) {
    let best = null, bestD = Infinity
    for (const t of this.targets) { const d = Math.hypot(t.x - x, t.y - y); if (d < t.reach && d < bestD) { best = t.pk; bestD = d } }
    return best
  }

  /** Whether (x, y) is over the inner globe nested in the middle: there the globe's own faces come first. */
  inHole(x, y) { return !!this.hole && Math.hypot(x - this.hole.x, y - this.hole.y) < this.hole.r }

  /** Where `pk` sits on the picked sphere, in the globe's own space (the globe turns it to the front when their card
   *  opens), or null. */
  direction(pk) {
    const b = this.picked, i = b?.index.get(pk)
    return i == null || i >= b.top.length ? null : b.points[i]
  }

  /** Where `pk` is on screen on the `hop` sphere drawn last frame (any sphere when null), with its front-ness, or null. */
  screenPoint(pk, hop = null) {
    for (const [h, s] of this.placed) {
      if (hop != null && h !== hop) continue
      const i = s.b.index.get(pk)
      if (i == null) continue
      const q = project(turn(s.m, s.b.points[i]))
      return { x: s.cx + q.x * s.r, y: s.cy + q.y * s.r, front: q.front }
    }
    return null
  }
}
