// Where a picked hop's people sit on its sphere (Logen 2026-11-25: "a 360 3d globe view of that ring", not a flat ring
// at the edge): the web twin of Apple Models/GlobeSphereField.swift (PR 2526). Its people are spread over the whole
// surface, best first from the pole that faces you when the globe is at rest, so the best sit nearest the front and the
// haze wraps round the back. Points come out on the unit sphere in the globe's own space, so the camera turn that spins
// the inner globe spins this one too. A Fibonacci spiral from the pole spreads them evenly; a small twist from each key
// keeps it from reading as a pattern. Pure; test/globe-hop-sphere.test.mjs pins it to the Swift output.
import { hazeHash } from "./globe-haze-field.js"
import { qMatrix, IDENTITY } from "./wot-globe.js"

/** Each point's turn round the pole is nudged by up to this, radians, from its key. */
export const TWIST = 0.35
/** How far away the sphere is seen from, in radii: the near side a little bigger than the far side. */
export const EYE = 3.4

const norm = ([x, y, z]) => { const l = Math.hypot(x, y, z) || 1; return [x / l, y / l, z / l] }
const cross = ([ax, ay, az], [bx, by, bz]) => [ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx]

/** The point of the globe that faces you at rest: the one the resting turn `rest` brings to the front (+z). The web's
 *  globe rests at IDENTITY (wot-globe.js home), so that is +z. */
export function pole(rest = IDENTITY) {
  const m = qMatrix(rest) // world -> view; its transpose takes the front back into the globe's own space
  return norm([m[6], m[7], m[8]])
}

/** Unit-sphere points for `keys`, best first: the first at the pole, the last at the far side. -> [[x, y, z]] */
export function points(keys, p = pole()) {
  p = norm(p)
  const helper = Math.abs(p[1]) < 0.9 ? [0, 1, 0] : [1, 0, 0]
  const u = norm(cross(helper, p)), v = cross(p, u)
  const n = Math.max(keys.length, 1), golden = Math.PI * (3 - Math.sqrt(5))
  return keys.map((key, i) => {
    // Equal area per point: the cosine of the angle from the pole falls evenly from 1 to -1.
    const c = 1 - 2 * (i + 0.5) / n, s = Math.sqrt(Math.max(0, 1 - c * c))
    const a = i * golden + TWIST * (2 * hazeHash(key).wobble - 1), ca = Math.cos(a), sa = Math.sin(a)
    return [p[0] * c + u[0] * s * ca + v[0] * s * sa, p[1] * c + u[1] * s * ca + v[1] * s * sa, p[2] * c + u[2] * s * ca + v[2] * s * sa]
  })
}

const FIT = Math.sqrt(EYE * EYE - 1) / EYE
/** A point already turned by the camera, against the sphere's outline: `x`, `y` within -1..1 of its centre (y down),
 *  `scale` for perspective, and `front` from 0 at the back to 1 at the front. Writes into `into` when given. */
export function project([x, y, z], into = {}) {
  const s = EYE / (EYE - z)
  into.x = x * s * FIT; into.y = -y * s * FIT; into.scale = s; into.front = (z + 1) / 2
  return into
}

/** `p` turned by the rotation matrix `m` (qMatrix, rows first). */
export const turn = (m, [x, y, z]) => [m[0] * x + m[1] * y + m[2] * z, m[3] * x + m[4] * y + m[5] * z, m[6] * x + m[7] * y + m[8] * z]
