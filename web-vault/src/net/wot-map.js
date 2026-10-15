// The Web of Trust map, as the iPhone draws its 2D map (HavenApp Models/GlobeFlat.swift, TrustMap.direction): you
// at the middle of a big open plane, your follows spread through the zone around you, the extended network through
// the next zone out, the further-out people through the outermost. A person's place comes from their key, so they
// sit in the same place every time, and on the web where they sit on the phone. Pure maths: the screen
// (WotScreen.jsx) draws it, and only what's on screen.
import { fraction } from "./wot.js"

// TrustMap's shell radii, and GlobeFlat's zones on the map as fractions of the rim.
const RING = 1.0, CLOSE = 1.3, OUTER = 1.62
export const ZONES = [
  { radius: 0, inner: 0, outer: 0 },
  { radius: RING, inner: 0.06, outer: 0.64 }, // your follows are the web: most of the map
  { radius: CLOSE, inner: 0.68, outer: 0.83 }, // extended network
  { radius: OUTER, inner: 0.86, outer: 0.98 }, // further out
]
export const RIM = 1.0
/** The zone each layer is drawn in. */
export const LAYER_ZONE = { me: 0, follow: 1, extended: 2, further: 3 }

/** TrustMap.direction: a longitude and an even height from the key, the point on the unit sphere. */
export function direction(pubkey) {
  const longitude = fraction(pubkey, 0) * 2 * Math.PI
  const z = fraction(pubkey, 8) * 2 - 1
  const r = Math.sqrt(1 - z * z)
  return [r * Math.cos(longitude), r * Math.sin(longitude), z]
}

/** GlobeFlat.place for someone on a zone's shell: the angle round the map is their longitude; their height picks
 *  where across the zone they sit, evenly by area. -> [x, y] in map units (the rim is 1). */
export function place(pubkey, zoneIndex) {
  const zone = ZONES[zoneIndex]
  if (!zone || zoneIndex === 0) return [0, 0]
  const [x, y, z] = direction(pubkey)
  const angle = Math.atan2(y, x)
  const u = (Math.min(1, Math.max(-1, z)) + 1) / 2
  const r = Math.sqrt(zone.inner * zone.inner + (zone.outer * zone.outer - zone.inner * zone.inner) * u)
  return [Math.cos(angle) * r * RIM, Math.sin(angle) * r * RIM]
}

/** How far apart two follows' faces stay, in map units: a little more than touching (GlobeFlat.faceRoom 1.12) for a
 *  face drawn at zoom 1 on a phone-sized plane (unit 1300). */
export const FACE_ROOM = (2 * 11 * 1.25 * 1.12) / 1300

/**
 * Nudge points apart until none are closer than `room`, keeping each inside its zone's ring (`inner`..`outer`), as the
 * iPhone keeps faces from piling up. Pairs are found through a grid, so it stays quick for thousands. Deterministic:
 * the same points always end in the same places. Changes `pts` ([{ pk, x, y }]) in place.
 */
export function spread(pts, room, inner, outer, rounds = 40) {
  const ordered = [...pts].sort((a, b) => (a.pk < b.pk ? -1 : 1))
  for (let round = 0; round < rounds; round++) {
    const grid = new Map()
    const cell = (x, y) => `${Math.floor(x / room)},${Math.floor(y / room)}`
    for (const p of ordered) { const k = cell(p.x, p.y); const c = grid.get(k); if (c) c.push(p); else grid.set(k, [p]) }
    let moved = false
    for (const p of ordered) {
      const gx = Math.floor(p.x / room), gy = Math.floor(p.y / room)
      for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
        for (const q of grid.get(`${gx + dx},${gy + dy}`) ?? []) {
          if (q.pk <= p.pk) continue
          let vx = q.x - p.x, vy = q.y - p.y, d = Math.hypot(vx, vy)
          if (d >= room) continue
          if (d < 1e-9) { const a = fraction(p.pk + q.pk, 0) * 2 * Math.PI; vx = Math.cos(a); vy = Math.sin(a); d = 1e-9 }
          const push = (room - d) / 2 / Math.max(d, 1e-9)
          p.x -= vx * push; p.y -= vy * push; q.x += vx * push; q.y += vy * push
          moved = true
        }
      }
    }
    for (const p of ordered) {
      const r = Math.hypot(p.x, p.y)
      const held = Math.min(outer, Math.max(inner, r))
      if (r > 1e-9 && held !== r) { p.x *= held / r; p.y *= held / r }
    }
    if (!moved) break
  }
  return pts
}

/**
 * Everyone the map draws, placed once: [{ pk, layer, x, y }] with you first, then follows, extended, further.
 * Follows' faces are spread so they don't pile up; the dots outside stay where their keys put them. The screen keeps
 * this and only moves the camera.
 */
export function layout(web, further) {
  const nodes = [{ pk: web.me, layer: "me", x: 0, y: 0 }]
  const add = (list, layer) => list.map(pk => { const [x, y] = place(pk, LAYER_ZONE[layer]); return { pk, layer, x, y } })
  const faces = add(web.follows, "follow")
  spread(faces, FACE_ROOM, ZONES[1].inner, ZONES[1].outer)
  nodes.push(...faces, ...add(web.extended, "extended"), ...add(further, "further"))
  return nodes
}

/** GlobeFlat.unit: points per map unit at zoom 1, a plane three to four screens across, never less than a few
 *  screens on a big one. */
export function unit(width, height) {
  const side = Math.min(width, height)
  return Math.max(1300 * Math.min(1, side / 620), 1.6 * side)
}

/** GlobeFlat.scale: faces and dots shrink as you zoom out, less than the map does, so they stay visible. */
export const scale = zoom => 1.25 * Math.min(1.4, Math.max(0.5, Math.sqrt(zoom)))

/** Where a map point is on screen: `offset` is where you (the middle of the network) sit, in points from the middle
 *  of the screen. */
export function toScreen(x, y, cam, width, height) {
  const u = unit(width, height) * cam.zoom
  return [width / 2 + cam.offset[0] + x * u, height / 2 + cam.offset[1] + y * u]
}

/**
 * The camera, as GlobeFlat.Camera: a drag moves it, a flick carries on and slows, a pinch or wheel zooms (here about
 * the pointer, as a map on a computer does), and home glides back to you. Plain objects, so tests can drive it.
 */
export const ZOOM_MIN = 0.3, ZOOM_MAX = 2.5, MARGIN = 120, DECAY = 3.5, MAX_SPEED = 5000

export const newCamera = () => ({ offset: [0, 0], velocity: [0, 0], zoom: 1, homing: false, target: null })
export const moving = cam => cam.homing || cam.velocity[0] !== 0 || cam.velocity[1] !== 0

/** How far you can be from the middle of the screen: the network's edge plus MARGIN can come in to the screen's nearer
 *  side, no further, so the empty corners past the round network stay out of reach. */
export function limit(cam, width, height) {
  const reach = RIM * unit(width, height) * cam.zoom + MARGIN
  return Math.max(0, reach - Math.min(width, height) / 2)
}

function clamp(p, cam, width, height) {
  const l = limit(cam, width, height), d = Math.hypot(p[0], p[1])
  return d > l ? [p[0] * l / d, p[1] * l / d] : p
}

export function pan(cam, dx, dy, width, height) {
  return { ...cam, homing: false, target: null, velocity: [0, 0], offset: clamp([cam.offset[0] + dx, cam.offset[1] + dy], cam, width, height) }
}

/** Let go at `vx, vy` points a second. */
export function fling(cam, vx, vy) {
  const speed = Math.hypot(vx, vy)
  const k = speed > MAX_SPEED ? MAX_SPEED / speed : 1
  return { ...cam, velocity: [vx * k, vy * k] }
}

/** Zoom by `factor` about the screen point `(px, py)` (the middle of the screen when left out): the map point under it
 *  stays under it. */
export function zoomBy(cam, factor, width, height, px = width / 2, py = height / 2) {
  const z = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, cam.zoom * factor))
  const k = z / cam.zoom
  const qx = px - width / 2, qy = py - height / 2
  const next = { ...cam, homing: false, target: null, zoom: z, offset: [qx + (cam.offset[0] - qx) * k, qy + (cam.offset[1] - qy) * k] }
  return { ...next, offset: clamp(next.offset, next, width, height) }
}

/** Glide back to you at zoom 1 (double-click, the Me button). */
export const home = cam => ({ ...cam, velocity: [0, 0], homing: true, target: { offset: [0, 0], zoom: 1 } })

/** Glide so the map point `(x, y)` comes to the middle of the screen, at least at zoom 1 (a person picked in My Web). */
export function glideTo(cam, x, y, width, height) {
  const zoom = Math.max(1, cam.zoom), u = unit(width, height) * zoom
  const offset = clamp([-x * u, -y * u], { ...cam, zoom }, width, height)
  return { ...cam, velocity: [0, 0], homing: true, target: { offset, zoom } }
}

/** Advance `dt` seconds: a glide (home, or to someone), or a flick slowing down and sliding along the edge. */
export function step(cam, dt, width, height) {
  if (cam.homing) {
    const t = cam.target ?? { offset: [0, 0], zoom: 1 }
    const glide = 1 - Math.exp(-dt * 6)
    const offset = [cam.offset[0] + (t.offset[0] - cam.offset[0]) * glide, cam.offset[1] + (t.offset[1] - cam.offset[1]) * glide]
    const zoom = cam.zoom + (t.zoom - cam.zoom) * glide
    if (Math.hypot(offset[0] - t.offset[0], offset[1] - t.offset[1]) < 0.5 && Math.abs(zoom - t.zoom) < 0.002) return { ...cam, offset: t.offset, zoom: t.zoom, homing: false, target: null }
    return { ...cam, offset, zoom }
  }
  if (!moving(cam)) return cam
  const next = [cam.offset[0] + cam.velocity[0] * dt, cam.offset[1] + cam.velocity[1] * dt]
  const held = clamp(next, cam, width, height)
  let v = cam.velocity
  if (held[0] !== next[0] || held[1] !== next[1]) {
    const d = Math.hypot(...held)
    if (d > 0) { const out = [held[0] / d, held[1] / d], dot = Math.max(0, v[0] * out[0] + v[1] * out[1]); v = [v[0] - out[0] * dot, v[1] - out[1] * dot] }
    else v = [0, 0]
  }
  const decay = Math.exp(-dt * DECAY)
  v = [v[0] * decay, v[1] * decay]
  if (Math.hypot(...v) < 8) v = [0, 0]
  return { ...cam, offset: held, velocity: v }
}

/** Screen sizes at a zoom: your face, a follow's face, an extended-network dot, a further-out dot. */
export function sizes(zoom) {
  const s = scale(zoom)
  return { me: 20 * s, follow: 11 * s, extended: 2.6 * s, further: 1.7 * s }
}

/** The nodes on screen (with a margin so a face half off the edge still draws), with their screen points.
 *  -> [{ node, sx, sy }] */
export function visible(nodes, cam, width, height, pad = 40) {
  const u = unit(width, height) * cam.zoom, cx = width / 2 + cam.offset[0], cy = height / 2 + cam.offset[1]
  const out = []
  for (const node of nodes) {
    const sx = cx + node.x * u, sy = cy + node.y * u
    if (sx < -pad || sy < -pad || sx > width + pad || sy > height + pad) continue
    out.push({ node, sx, sy })
  }
  return out
}

/**
 * Who a tap at `(px, py)` hits among the drawn points: the nearest within reach, faces before dots (a dot under a face
 * isn't what was meant). Dots can be tapped from a little further than they're drawn. -> node or null
 */
export function hit(drawn, px, py, zoom) {
  const sz = sizes(zoom)
  let best = null, bestScore = Infinity
  for (const d of drawn) {
    const r = d.node.layer === "me" ? sz.me : d.node.layer === "follow" ? sz.follow : Math.max(10, sz[d.node.layer] * 3)
    const dist = Math.hypot(d.sx - px, d.sy - py)
    if (dist > r) continue
    const score = dist / r + (d.node.layer === "me" || d.node.layer === "follow" ? 0 : 1)
    if (score < bestScore) { bestScore = score; best = d.node }
  }
  return best
}

/** The faint dashed rings where one zone gives way to the next, in map units. */
export const zoneEdges = () => [1, 2].map(i => (ZONES[i].outer + ZONES[i + 1].inner) / 2 * RIM)
