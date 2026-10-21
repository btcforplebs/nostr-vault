// The Web of Trust globe, as the iPhone draws it (HavenApp Models/TrustMap.swift, GlobeEdge.swift, GlobeScene's
// Projector): you in the middle, your follows on the unit sphere round you, the extended network on a shell just past
// them, everyone further out on a faint outer shell. A person's spot comes from their key, so they sit in the same
// place every time. Faces fade and shrink as they roll toward the rim and round the back, and a face that would pile
// onto a nearer one gives up its seat and fades to a dot. Pure maths: the screen (WotGlobe.jsx) draws it.
import { fraction } from "./wot.js"

/** TrustMap's shell radii: you at 0, follows, the extended network, further out. */
export const RADIUS = { me: 0, follow: 1.0, extended: 1.3, further: 1.62 }

/** How brightly each layer of the picker (wot.js LAYERS) draws your follows, the extended network and further out
 *  (TrustMap.layerWeights). The others go out, so picking a layer visibly empties the globe; the outer shells' faint
 *  dots are lit brighter when they're all that's left. */
export const LAYER_WEIGHTS = {
  everyone: { follow: 1, extended: 1, further: 1 },
  following: { follow: 1, extended: 0, further: 0 },
  close: { follow: 0, extended: 1.6, further: 0 },
  furtherOut: { follow: 0, extended: 0, further: 1.6 },
}

/** TrustMap.direction: a longitude and an even height from the key, the point on the unit sphere. */
export function direction(pubkey) {
  const longitude = fraction(pubkey, 0) * 2 * Math.PI
  const z = fraction(pubkey, 8) * 2 - 1
  const r = Math.sqrt(1 - z * z)
  return [r * Math.cos(longitude), r * Math.sin(longitude), z]
}

/** Faces past your follows, as the iPhone's Everyone layer: this many, picked from six times as many candidates
 *  because many people further out have no picture. */
export const OUTER_FACES = 36, OUTER_CANDIDATES = OUTER_FACES * 6
/** Candidates for those faces: most linked first (buildWeb and filterWeb keep both lists in that order), taken in turn
 *  from the extended network and further out so both outer shells get pictures. */
export function outerFaces(web, count = OUTER_CANDIDATES) {
  const ext = web.extended.slice(0, count), far = web.further.slice(0, count), out = []
  for (let i = 0; out.length < count && (i < ext.length || i < far.length); i++) {
    if (i < ext.length) out.push(ext[i])
    if (i < far.length && out.length < count) out.push(far[i])
  }
  return out
}

/** The first `count` candidates with a picture: only they become faces. */
export const pictured = (candidates, hasPicture, count = OUTER_FACES) => candidates.filter(hasPicture).slice(0, count)

/** Everyone the globe draws, placed once: [{ pk, layer, face, p: [x, y, z] }], you first, then follows, extended,
 *  further. Your follows are faces, and so are `faces` past them (added if the capped lists left them out). */
export function layout(web, further, faces = []) {
  const at = (pk, layer, face) => ({ pk, layer, face, p: direction(pk).map(v => v * RADIUS[layer]) })
  const outer = new Set(faces)
  const nodes = [
    { pk: web.me, layer: "me", face: true, p: [0, 0, 0] },
    ...web.follows.map(pk => at(pk, "follow", true)),
    ...web.extended.map(pk => at(pk, "extended", outer.delete(pk))),
    ...further.map(pk => at(pk, "further", outer.delete(pk))),
  ]
  for (const pk of outer) { const layer = web.layerOf?.(pk); if (layer === "extended" || layer === "further") nodes.push(at(pk, layer, true)) }
  return nodes
}

// Quaternions as [w, x, y, z]: the camera's turn.
const qMul = (a, b) => [
  a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
  a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
  a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
  a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
]
const qNorm = q => { const l = Math.hypot(...q) || 1; return q.map(v => v / l) }
export const qAxis = (angle, [x, y, z]) => { const l = Math.hypot(x, y, z) || 1, s = Math.sin(angle / 2) / l; return [Math.cos(angle / 2), x * s, y * s, z * s] }
export const IDENTITY = [1, 0, 0, 0]
const qDot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
function qSlerp(a, b, t) {
  let d = qDot(a, b)
  if (d < 0) { b = b.map(v => -v); d = -d }
  if (d > 0.9995) return qNorm(a.map((v, i) => v + (b[i] - v) * t))
  const th = Math.acos(d), s = Math.sin(th)
  const ka = Math.sin((1 - t) * th) / s, kb = Math.sin(t * th) / s
  return a.map((v, i) => v * ka + b[i] * kb)
}
/** The rotation matrix of a quaternion, rows first. */
export function qMatrix([w, x, y, z]) {
  return [
    1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
    2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
    2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
  ]
}
/** The shortest turn taking direction `a` to direction `b`. */
function qFromTo(a, b) {
  const na = Math.hypot(...a), nb = Math.hypot(...b)
  const [ax, ay, az] = a.map(v => v / na), [bx, by, bz] = b.map(v => v / nb)
  const d = ax * bx + ay * by + az * bz
  if (d < -0.999999) return qAxis(Math.PI, Math.abs(ax) < 0.9 ? [0, -az, ay] : [az, 0, -ax])
  return qNorm([1 + d, ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx])
}

/**
 * The camera, as GlobeCamera: a drag turns the globe under the finger, a flick keeps it spinning and slowing, the wheel
 * or a pinch zooms, and home glides back to the start. Plain objects, so tests can drive it. No idle drift: the web
 * draws nothing while the globe is still.
 */
export const DISTANCE = 4.2, ZOOM_MIN = 0.8, ZOOM_MAX = 2.4
export const DRAG_TURN = 0.005, FLICK_TURN = 0.003, FLICK_FLOOR = 350, MAX_SPIN = 2.5, SPIN_DECAY = 2.4, MAX_STEP = 1 / 20

export const newCamera = () => ({ q: IDENTITY, spin: [0, 0, 0], zoom: 1, zoomTarget: 1, target: null, dragging: false })
export const moving = cam => cam.dragging || cam.target !== null || cam.spin.some(v => v !== 0) || cam.zoom !== cam.zoomTarget

/** One finger moved by `dx`, `dy` points: turn under it. */
export function drag(cam, dx, dy) {
  const turn = qMul(qAxis(dx * DRAG_TURN, [0, 1, 0]), qAxis(dy * DRAG_TURN, [1, 0, 0]))
  return { ...cam, q: qNorm(qMul(turn, cam.q)), target: null, spin: [0, 0, 0] }
}

/** Let go at `vx`, `vy` points a second: keep turning that way, unless it was just letting go or motion is reduced. */
export function flick(cam, vx, vy, reduceMotion = false) {
  const speed = Math.hypot(vx, vy)
  if (reduceMotion || speed <= FLICK_FLOOR) return { ...cam, spin: [0, 0, 0] }
  let v = [vy * FLICK_TURN, vx * FLICK_TURN, 0]
  const rate = Math.hypot(...v)
  if (rate > MAX_SPIN) v = v.map(c => c * MAX_SPIN / rate)
  return { ...cam, spin: v }
}

/** Zoom by `factor`, glided to (the wheel's steps blur into one move); reduced motion jumps. */
export function zoomBy(cam, factor, reduceMotion = false) {
  const z = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, cam.zoomTarget * factor))
  return { ...cam, zoomTarget: z, zoom: reduceMotion ? z : cam.zoom }
}
/** Zoom straight to `factor` times the current zoom, no glide: a pinch follows the fingers. */
export function zoomNow(cam, factor) {
  const z = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, cam.zoom * factor))
  return { ...cam, zoom: z, zoomTarget: z }
}

/** GlobeCamera.facing: the turn that brings `dir` to the front, a little up and right of the middle, so whoever it is
 *  never hides behind you. */
export const facing = dir => qFromTo(dir, [0.42, 0.30, 1])
/** Glide to the turn `q` at zoom 1 (a person picked in My Web). */
export const flyTo = (cam, q) => ({ ...cam, target: q, spin: [0, 0, 0], zoomTarget: 1 })
/** Back to the start (double-click, the Me button). */
export const home = cam => flyTo(cam, IDENTITY)

/** Advance `dt` seconds: a fly-to, or a spin dying away, and the zoom easing to its target. Reduced motion cuts. */
export function step(cam, dt, reduceMotion = false) {
  dt = Math.min(MAX_STEP, Math.max(0, dt))
  let { q, spin, zoom, target } = cam
  if (target) {
    q = reduceMotion ? target : qNorm(qSlerp(q, target, 1 - Math.exp(-dt * 5)))
    if (reduceMotion || Math.abs(qDot(q, target)) > 0.99999) { q = target; target = null }
  } else if (!cam.dragging) {
    const speed = Math.hypot(...spin)
    if (speed > 0.0005 && !reduceMotion) {
      // The exact turn while the spin decays over this step, so it turns the same at 60 and 120 Hz.
      const decay = Math.exp(-dt * SPIN_DECAY)
      q = qNorm(qMul(qAxis(speed * (1 - decay) / SPIN_DECAY, spin), q))
      spin = spin.map(v => v * decay)
    } else spin = [0, 0, 0]
  }
  zoom = reduceMotion || Math.abs(cam.zoomTarget - zoom) < 0.0005 ? cam.zoomTarget : zoom + (cam.zoomTarget - zoom) * (1 - Math.exp(-dt * 7))
  return { ...cam, q, spin, zoom, target }
}

/** GlobeCamera.unit: screen points per unit of world at zoom 1. Upright like a phone, the follows' sphere spans just
 *  inside the width (phoneFill 0.96); otherwise it keeps its framing inside the shorter side. */
export function unit(width, height) {
  if (width > height) return Math.min(width, height) * 0.40 * DISTANCE * 0.92
  const r = RADIUS.follow, d = DISTANCE
  return width * 0.96 / 2 * Math.sqrt(d * d - r * r) / r
}

/** A projector for one frame: world point -> { x, y, depth, scale } or null when it has passed the lens. `depth` runs
 *  toward the viewer, about -1.6 at the back of the outer shell to 1.6 at the front. */
export function projector(cam, width, height) {
  const m = qMatrix(cam.q), camZ = DISTANCE / cam.zoom, u = unit(width, height), mx = width / 2, my = height / 2
  return ([x, y, z]) => {
    const vx = m[0] * x + m[1] * y + m[2] * z, vy = m[3] * x + m[4] * y + m[5] * z, vz = m[6] * x + m[7] * y + m[8] * z
    const gap = camZ - vz
    if (gap < 0.45) return null // zoomed in, the outer shell passes the camera
    const s = 1 / gap
    return { x: mx + vx * s * u, y: my - vy * s * u, depth: vz, scale: s * camZ }
  }
}

/** The outline of a shell of radius `r` on screen, in points: a sphere seen from `d` away. */
export function outline(r, cam, width, height) {
  const d = DISTANCE / cam.zoom
  return d > r ? unit(width, height) * r / Math.sqrt(d * d - r * r) : Infinity
}

// GlobeEdge: everything fades as a smooth function of depth, so a turning globe never steps.
export const FACE_FULL = 0.25, FACE_GONE = -0.1
export const smoothstep = (a, b, x) => { const t = Math.min(1, Math.max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
/** How much of a face shows at `depth`: 1 at the front, 0 round the back. */
export const faceShown = depth => smoothstep(FACE_GONE, FACE_FULL, depth)
/** A face's radius as it fades: it shrinks to three fifths, landing on the dot it becomes rather than vanishing. */
export const faceRadius = (r, shown) => r * (0.6 + 0.4 * shown)
/** Brightness of a dot at `depth`: full in front, a third round the back. */
export const dotLight = depth => 0.35 + 0.65 * smoothstep(-0.45, 0.05, depth)
/** A seat's fade eased toward seated (1) or not (0) over about a quarter second; reduced motion cuts. */
export function seatFade(current, seated, dt, reduceMotion = false) {
  const target = seated ? 1 : 0
  if (reduceMotion) return target
  const next = current + (target - current) * (1 - Math.exp(-dt * 12))
  return Math.abs(target - next) < 0.01 ? target : next
}

/** Base sizes in points at zoom 1, before perspective: your face, a follow's face, a face past your follows (two points
 *  smaller, as Everyone's), the two kinds of dot. */
export const SIZE = { me: 20, follow: 11, outer: 9, extended: 2.6, further: 1.7 }
/** How bright a face past your follows is drawn, as Everyone's outer faces. */
export const OUTER_ALPHA = 0.8
/** A face's size on screen: its base size, nearer is bigger, zoom helps up to a point. */
export const faceSize = (kind, p, zoom) => SIZE[kind] * p.scale * Math.min(zoom, 1.8)

/**
 * Which faces get a seat this frame: leading faces first (you, your follows), each front to back; a face is seated
 * unless a seated face is within `room` times their radii. Faces round the back (past FACE_GONE) get none. Found
 * through a grid, so it stays quick for thousands. `faces` is [{ pk, x, y, depth, r, lead }]. -> Set of seated pks
 */
export function seats(faces, room = 1.12) {
  const order = faces.filter(f => f.depth >= FACE_GONE).sort((a, b) => (b.lead ? 1 : 0) - (a.lead ? 1 : 0) || b.depth - a.depth)
  const maxR = order.reduce((m, f) => Math.max(m, f.r), 1), cell = 2 * maxR * room
  const grid = new Map(), out = new Set()
  for (const f of order) {
    const gx = Math.floor(f.x / cell), gy = Math.floor(f.y / cell)
    let free = true
    for (let dx = -1; dx <= 1 && free; dx++) for (let dy = -1; dy <= 1 && free; dy++) {
      for (const g of grid.get(`${gx + dx},${gy + dy}`) ?? []) {
        if (Math.hypot(f.x - g.x, f.y - g.y) < (f.r + g.r) * room) { free = false; break }
      }
    }
    if (!free) continue
    out.add(f.pk)
    const k = `${gx},${gy}`, c = grid.get(k)
    if (c) c.push(f); else grid.set(k, [f])
  }
  return out
}

/** On screen, with a margin so a face half off the edge still draws. */
export const onScreen = (x, y, width, height, pad = 40) => x >= -pad && y >= -pad && x <= width + pad && y <= height + pad

/**
 * Who a tap at `(px, py)` hits among what was drawn ([{ node, x, y, depth, r, shown }]): the nearest face showing at
 * least half, then the nearest front dot within a fingertip. -> node or null
 */
export function hit(drawn, px, py) {
  let best = null, bestD = Infinity
  for (const d of drawn) {
    if (!d.face || d.shown < 0.5 || d.depth <= -0.15) continue
    const dist = Math.hypot(d.x - px, d.y - py)
    if (dist <= Math.max(d.r + 6, 22) && dist < bestD) { best = d.node; bestD = dist }
  }
  if (best) return best
  for (const d of drawn) {
    if (d.face || d.depth <= 0) continue
    const dist = Math.hypot(d.x - px, d.y - py)
    if (dist <= 12 && dist < bestD) { best = d.node; bestD = dist }
  }
  return best
}
