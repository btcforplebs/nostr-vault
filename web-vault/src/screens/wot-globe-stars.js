// The globe's stars, drawn every frame while it moves (WotGlobe.jsx). On the GPU where there is one (GlStars, at the
// bottom); this 2D pass is for a browser without WebGL. A big web is thousands of stars, so this pass
// allocates nothing per star: projecting writes into one reused point, stars are filed by number (kind x weight x
// brightness band) into reused coordinate lists, and each list is one path and one fill. Same maths as
// net/wot-globe.js projector() and dotLight(); the perf review of 2026-11-18 found the old pass (a new object, a
// template-string Map key and a record per star per frame) at 3 s of script per 10 s of dragging.
import { DISTANCE, qMatrix, unit, SIZE } from "../net/wot-globe.js"

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

// The stars on the GPU (W11 of the 2026-11-20 perf audit: an arc per star, its fill and the loop round them were about
// half of a drag frame on a phone). Each star's place, colour and weight go up once per scene; a frame sends only the
// camera, and the vertex shader projects (pointProjector), bands (lightBand) and colours (WotGlobe's star fill) each
// star as the 2D pass does. Faces, threads and labels stay on the 2D canvas over it. Without WebGL, or once its
// context is lost, WotGlobe draws the stars with StarBands as before.

/** Floats per star in packStars' array: x, y, z, r, g, b (0..1), alpha at the back, at the front, weight, base size. */
export const STRIDE = 10

/** The GPU's copy of the stars: `stars` are indexes into `nodes`, `weight` each node's weight, `colours` STAR or
 *  STAR_DAY. A follow's star is a ring star (no star is hot: a traced path's people are all faces). */
export function packStars(nodes, stars, weight, colours) {
  const a = new Float32Array(stars.length * STRIDE)
  for (let n = 0; n < stars.length; n++) {
    const i = stars[n], node = nodes[i], kind = node.layer === "follow" ? "ring" : node.layer, c = colours[kind], o = n * STRIDE
    a[o] = node.p[0]; a[o + 1] = node.p[1]; a[o + 2] = node.p[2]
    a[o + 3] = c[0] / 255; a[o + 4] = c[1] / 255; a[o + 5] = c[2] / 255; a[o + 6] = c[3]; a[o + 7] = c[4]
    a[o + 8] = weight[i]; a[o + 9] = SIZE[kind]
  }
  return a
}

const VERTEX = `
attribute vec3 p; attribute vec3 rgb; attribute vec3 abw; attribute float size;
uniform vec3 r0; uniform vec3 r1; uniform vec3 r2; uniform float camZ; uniform float unit; uniform float dpr; uniform float zoomed; uniform vec2 view;
varying vec4 colour; varying float radius; varying float side;
void main() {
  float vz = dot(r2, p), gap = camZ - vz;
  if (gap < 0.45) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); gl_PointSize = 0.0; colour = vec4(0.0); radius = 0.0; side = 1.0; return; }
  float s = 1.0 / gap;
  vec2 at = vec2(view.x * 0.5 + dot(r0, p) * s * unit, view.y * 0.5 - dot(r1, p) * s * unit);
  float t = clamp((vz + 0.45) / 0.5, 0.0, 1.0), light = 0.35 + 0.65 * t * t * (3.0 - 2.0 * t);
  float band = min(3.0, floor((light - 0.35) / 0.65 * 4.0));
  float a = min(1.0, (abw.x + (abw.y - abw.x) * (band + 0.5) / 4.0) * abw.z);
  radius = size * s * camZ * zoomed * dpr;
  side = 2.0 * radius + 2.0;
  gl_PointSize = side;
  colour = vec4(rgb * a, a);
  gl_Position = vec4(at.x / view.x * 2.0 - 1.0, 1.0 - at.y / view.y * 2.0, 0.0, 1.0);
}`
const FRAGMENT = `
precision mediump float;
varying vec4 colour; varying float radius; varying float side;
void main() { gl_FragColor = colour * clamp(radius - length(gl_PointCoord - 0.5) * side + 0.5, 0.0, 1.0); }`

export class GlStars {
  /** -> a GlStars drawing on `canvas`, or null where WebGL isn't there. */
  static create(canvas) {
    try {
      const gl = canvas.getContext("webgl", { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false })
      return gl ? new GlStars(gl) : null
    } catch { return null }
  }
  constructor(gl) {
    this.gl = gl
    const shader = (type, src) => {
      const s = gl.createShader(type)
      gl.shaderSource(s, src); gl.compileShader(s)
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) ?? "shader")
      return s
    }
    const prog = this.prog = gl.createProgram()
    gl.attachShader(prog, shader(gl.VERTEX_SHADER, VERTEX)); gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FRAGMENT))
    gl.linkProgram(prog)
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog) ?? "program")
    gl.useProgram(prog)
    this.u = Object.fromEntries(["r0", "r1", "r2", "camZ", "unit", "dpr", "zoomed", "view"].map(k => [k, gl.getUniformLocation(prog, k)]))
    this.buffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer)
    for (const [name, n, at] of [["p", 3, 0], ["rgb", 3, 3], ["abw", 3, 6], ["size", 1, 9]]) {
      const loc = gl.getAttribLocation(prog, name)
      gl.enableVertexAttribArray(loc)
      gl.vertexAttribPointer(loc, n, gl.FLOAT, false, STRIDE * 4, at * 4)
    }
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    this.n = 0
  }
  /** The stars to draw from now on (packStars). */
  load(packed) {
    const gl = this.gl
    gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer)
    gl.bufferData(gl.ARRAY_BUFFER, packed, gl.STATIC_DRAW)
    this.n = packed.length / STRIDE
  }
  /** One frame for camera `cam` on a `width` x `height` (css px) globe. */
  draw(cam, width, height, dpr) {
    const gl = this.gl, u = this.u, m = qMatrix(cam.q), camZ = DISTANCE / cam.zoom
    gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight)
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT)
    if (!this.n) return
    gl.uniform3f(u.r0, m[0], m[1], m[2]); gl.uniform3f(u.r1, m[3], m[4], m[5]); gl.uniform3f(u.r2, m[6], m[7], m[8])
    gl.uniform1f(u.camZ, camZ); gl.uniform1f(u.unit, unit(width, height)); gl.uniform1f(u.dpr, dpr)
    gl.uniform1f(u.zoomed, Math.min(cam.zoom, 1.8)); gl.uniform2f(u.view, width, height)
    gl.drawArrays(gl.POINTS, 0, this.n)
  }
  /** Gives the GPU its memory back (a globe closing; browsers keep only a few contexts). */
  release() {
    this.gl.getExtension("WEBGL_lose_context")?.loseContext()
  }
}
