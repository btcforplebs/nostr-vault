// How a 3D object (readers/sno.js geometry) becomes 2D drawing: turned by yaw and pitch, fitted to the canvas, and
// lit. DECK-0003 §4 rules followed: both sides of every face are drawn (no culling by winding); a lit face uses its
// own flat normal, never one smoothed across vertices, and its back is lit as the other side of the same face; a
// face with its own colour (facecolors) is filled with it, else with its corners' colours averaged (a 2D canvas
// can't interpolate a triangle); `lines` draws each face edge once with its two end colours, or a polyline through
// the vertices when there are no faces; every vertex is drawn as a point in every mode. Nothing moves a vertex.
// Painter's order (far to near), as the WoT globe draws: faces that cut through each other may overlap wrongly,
// accepted for this content (the plan's known limit).

const LIGHT = norm([0.35, 0.6, 0.72]) // from up-right, toward the viewer
const AMBIENT = 0.38, BACK = 0.78

function norm(v) { const l = Math.hypot(...v) || 1; return v.map(x => x / l) }
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

/** A point turned by yaw (about Y) then pitch (about X). */
export function turn([x, y, z], yaw, pitch) {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch)
  const x1 = x * cy + z * sy, z1 = -x * sy + z * cy
  return [x1, y * cp - z1 * sp, y * sp + z1 * cp]
}

/** "rgb(…)" from a 0..1 colour times a light level. */
export const css = (c, k = 1) => `rgb(${c.map(v => Math.round(Math.max(0, Math.min(1, v * k)) * 255)).join(",")})`

/** The light on a face whose view-space normal is `n`: ambient plus diffuse, the back side darker. */
export function shade(n) {
  const front = n[2] >= 0
  const f = front ? n : n.map(x => -x)
  return (AMBIENT + (1 - AMBIENT) * Math.max(0, dot(norm(f), LIGHT))) * (front ? 1 : BACK)
}

/**
 * The draw list for one frame, far to near. `size` is the canvas side in CSS pixels.
 * -> [{ type: "face", pts: [[x,y]x3], fill } | { type: "line", a, b, from, to } | { type: "point", at, fill, r } | { type: "box", pts }]
 */
export function frame(geo, { yaw = 0, pitch = 0, size = 300, accent = [1, 0.55, 0.15] } = {}) {
  const scale = (size * 0.42) / geo.radius
  const view = geo.points.map(p => turn(p, yaw, pitch))
  const at = v => [size / 2 + v[0] * scale, size / 2 - v[1] * scale] // y up on screen
  const ops = []
  if (geo.mode === "solid") {
    geo.faces.forEach((f, i) => {
      const [a, b, c] = f.map(j => view[j])
      const n = cross(sub(b, a), sub(c, a))
      const colour = geo.faceColors?.[i] ?? [0, 1, 2].map(k => (geo.colors[f[0]][k] + geo.colors[f[1]][k] + geo.colors[f[2]][k]) / 3)
      ops.push({ type: "face", depth: (a[2] + b[2] + c[2]) / 3, pts: [a, b, c].map(at), fill: css(colour, Math.hypot(...n) ? shade(n) : AMBIENT) })
    })
  } else if (geo.mode === "lines") {
    const edges = new Set()
    const edge = (i, j) => {
      const k = i < j ? `${i},${j}` : `${j},${i}`
      if (edges.has(k)) return
      edges.add(k)
      ops.push({ type: "line", depth: (view[i][2] + view[j][2]) / 2, a: at(view[i]), b: at(view[j]), from: css(geo.colors[i]), to: css(geo.colors[j]) })
    }
    if (geo.faces.length) for (const [a, b, c] of geo.faces) { edge(a, b); edge(b, c); edge(c, a) }
    else for (let i = 1; i < view.length; i++) edge(i - 1, i)
  }
  const r = geo.mode === "points" ? Math.max(2, size / 90) : Math.max(1, size / 260)
  view.forEach((v, i) => ops.push({ type: "point", depth: v[2] + 1e-3, at: at(v), fill: css(geo.colors[i], geo.mode === "solid" ? 0.85 : 1), r }))
  for (const c of geo.placeholders ?? []) {
    const corners = [-0.5, 0.5].flatMap(x => [-0.5, 0.5].flatMap(y => [-0.5, 0.5].map(z => at(turn([c[0] + x, c[1] + y, c[2] + z], yaw, pitch)))))
    ops.push({ type: "box", depth: turn(c, yaw, pitch)[2], pts: corners, stroke: css(accent) })
  }
  return ops.sort((p, q) => p.depth - q.depth)
}

// The cube's 12 edges by corner index (corners in x, y, z binary order).
const BOX = [[0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7]]

/** Draws a frame's ops on a 2D context already scaled to CSS pixels. */
export function paint(ctx, ops) {
  ctx.lineJoin = "round"
  for (const op of ops) {
    if (op.type === "face") {
      ctx.beginPath(); ctx.moveTo(...op.pts[0]); ctx.lineTo(...op.pts[1]); ctx.lineTo(...op.pts[2]); ctx.closePath()
      ctx.fillStyle = op.fill; ctx.strokeStyle = op.fill; ctx.lineWidth = 0.6
      ctx.fill(); ctx.stroke() // the hairline stroke closes the seams between neighbours
    } else if (op.type === "line") {
      const g = ctx.createLinearGradient(...op.a, ...op.b)
      g.addColorStop(0, op.from); g.addColorStop(1, op.to)
      ctx.strokeStyle = g; ctx.lineWidth = 2
      ctx.beginPath(); ctx.moveTo(...op.a); ctx.lineTo(...op.b); ctx.stroke()
    } else if (op.type === "point") {
      ctx.fillStyle = op.fill
      ctx.beginPath(); ctx.arc(op.at[0], op.at[1], op.r, 0, Math.PI * 2); ctx.fill()
    } else if (op.type === "box") {
      ctx.strokeStyle = op.stroke; ctx.lineWidth = 1
      ctx.beginPath()
      for (const [i, j] of BOX) { ctx.moveTo(...op.pts[i]); ctx.lineTo(...op.pts[j]) }
      ctx.stroke()
    }
  }
}
