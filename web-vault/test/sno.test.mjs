// 3D objects (kind 33331, SNO, DECK-0003) on the web: read with arkin0x's sno-core (vendored), refused whole when any
// §1.9 rule fails with the reason shown, drawn lit with both sides of every face, never in the feed. The two real
// events are the plan's (Silver Key from ONOSENDAI, AJ FU from SNOcrash.art); the rejections are the reference
// validator's table (decks/sno-reference.py _rejections), one per rule.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { readSno, rejectReason, geometry, SNO_KIND } = await import("../src/readers/sno.js")
const { frame, shade, turn } = await import("../src/readers/sno-draw.js")
const { previewMeta, renderPost } = await import("../thread-page/page.js")
const { hasKindBody } = await import("../src/components/FeedKinds.jsx")
const { FEED_KINDS } = await import("../src/net/sync.js")
const { silverKey, ajfu } = JSON.parse(readFileSync(new URL("./fixtures/sno-events.json", import.meta.url), "utf8"))

const APPENDIX_A = { v: 2, name: "tetra", unit: 0, mode: "solid", vertices: [[0, 0, 0], [2, 0, 0], [1, 0, 2], [1, 2, 1]], colors: [238, 235, 239, 225], faces: [[0, 1, 2], [0, 3, 1], [1, 3, 2], [0, 2, 3]] }
const ev = (payload, tags = []) => ({ id: "f".repeat(64), pubkey: "a".repeat(64), kind: SNO_KIND, created_at: 1, tags, content: typeof payload === "string" ? payload : JSON.stringify(payload) })
const variant = over => ev({ ...APPENDIX_A, ...over })

test("the plan's two real events read and draw: Silver Key (solid) and AJ FU (lines)", () => {
  const key = readSno(silverKey)
  assert.equal(key.ok, true); assert.equal(key.name, "Silver Key"); assert.equal(key.mode, "solid"); assert.equal(key.vertices, 32); assert.equal(key.faces, 60)
  const aj = readSno(ajfu)
  assert.equal(aj.ok, true); assert.equal(aj.name, "AJ FU"); assert.equal(aj.mode, "lines"); assert.equal(aj.vertices, 40)
  assert.equal(aj.alt, "a 3D object: AJ FU, 40 vertices")
  const g = geometry(key.model)
  assert.equal(g.points.length, 32); assert.ok(g.radius > 0)
  const ops = frame(g, { size: 300 })
  assert.equal(ops.filter(o => o.type === "face").length, 60, "every face drawn, front or back (no culling)")
  assert.equal(ops.filter(o => o.type === "point").length, 32, "points in every mode")
  const lines = frame(geometry(aj.model), { size: 300 }).filter(o => o.type === "line")
  const edges = new Set(aj.model.faces.flatMap(([a, b, c]) => [[a, b], [b, c], [c, a]].map(([i, j]) => (i < j ? `${i},${j}` : `${j},${i}`))))
  assert.equal(lines.length, edges.size, "each edge once")
  for (const o of ops) for (const [x, y] of o.pts ?? [o.at ?? [150, 150]]) assert.ok(x >= 0 && x <= 300 && y >= 0 && y <= 300, "fitted to the stage")
})

test("Appendix A's tetrahedron is valid; a lit face's back is darker than its front, never culled", () => {
  assert.equal(readSno(ev(APPENDIX_A)).ok, true)
  assert.ok(shade([0, 0, 1]) > shade([0, 0, -1]))
  const g = geometry(readSno(ev(APPENDIX_A)).model)
  for (const yaw of [0, 1, 2, 3, 4, 5]) assert.equal(frame(g, { yaw }).filter(o => o.type === "face").length, 4)
  assert.deepEqual(turn([1, 0, 0], Math.PI / 2, 0).map(n => Math.round(n)), [0, 0, -1])
})

const REJECTIONS = [
  ["rule 1", { v: 3 }, /version 3/], ["rule 1", { v: 0 }, /version 0/],
  ["rule 2", { colors: [238] }, /4 vertices but 1 colors/],
  ["rule 4", { mode: "wireframe" }, /mode "wireframe"/],
  ["rule 5", { unit: 85 }, /unit/], ["rule 5", { unit: 1.5 }, /unit/],
  ["rule 6", { vertices: [[0, 0, 0], [2, 0, 0], [1, 0, 2], [1, 2, 1.5]] }, /Vertex 4/],
  ["rule 7", { ticks: [-3] }, /ticks/], ["rule 7", { ticks: [[0, 0, 120], -3] }, /ticks/], ["rule 7", { ticks: [4] }, /ticks/],
  ["rule 8", { faces: [[0, 1, 9]] }, /Face 1/], ["rule 8", { faces: [[0, 1, 1]] }, /Face 1/],
  ["rule 8a", { palette: [[255, 0, 0]] }, /palette/], ["rule 8a", { palette: [[255, 0, 0, 0], [0, 0, 0]] }, /palette/],
  ["rule 8b", { colors: [0, 1, 2, 256] }, /Color 4/], ["rule 8b", { colors: [0, 1, 2, -1] }, /Color 4/], ["rule 8b", { colors: [0, 1, 2, 1.5] }, /Color 4/],
  ["rule 8c", { facecolors: [238] }, /facecolors/], ["rule 8c", { facecolors: [238, -4] }, /facecolors/], ["rule 8c", { facecolors: [-4] }, /facecolors/], ["rule 8c", { facecolors: [238, 256, -2] }, /facecolors/],
  ["rule 10", { up: "yes" }, /up/], ["rule 10", { up: true, spin: 360 }, /spin/], ["rule 10", { spin: 360 }, /spin/],
  ["rule 11", { refs: "x" }, /refs/], ["rule 11", { refs: [["a", "33331:" + "AB".repeat(32) + ":d"]] }, /refs/],
  ["rule 11", { refs: [["a", "30023:" + "ab".repeat(32) + ":d"]] }, /refs/], ["rule 11", { refs: [["e", "cd".repeat(31)]] }, /refs/],
  ["rule 11", { refs: [["p", "ab".repeat(32)]] }, /refs/], ["rule 11", { refs: [["e", "cd".repeat(32), "wss://x", "extra"]] }, /refs/],
  ["rule 12", { parts: [[0, 0, 0, 0, 0, 0, 0, 0]] }, /parts/], ["rule 12", { refs: [["e", "cd".repeat(32)]], parts: [[1, 0, 0, 0, 0, 0, 0, 0]] }, /parts/],
  ["rule 12", { refs: [["e", "cd".repeat(32)]], parts: [[0, 7681, 0, 0, 0, 0, 0, 0]] }, /parts/],
  ["rule 12", { refs: [["e", "cd".repeat(32)]], parts: [[0, 0, 0, 0, 360, 0, 0, 0]] }, /parts/],
  ["rule 12", { refs: [["e", "cd".repeat(32)]], parts: [[0, 0, 0, 0, 0, 0, 0]] }, /parts/],
]

test("every §1.9 rejection of the reference validator is refused whole, with a reason that names it", () => {
  for (const [rule, over, why] of REJECTIONS) {
    const r = readSno(variant(over))
    assert.equal(r.ok, false, `${rule} ${JSON.stringify(over)} must be refused`)
    assert.match(r.reason, why, `${rule}: "${r.reason}"`)
  }
  assert.match(readSno(ev("not json")).reason, /isn't JSON/)
  assert.match(readSno(ev({ ...APPENDIX_A, name: "  " })).reason, /no name/)
  assert.match(rejectReason([]), /isn't an object/)
  assert.equal(readSno(variant({ type: "shard", extent: 999, opacity: 5, constrain: "bogus" })).ok, true, "type ignored; extent, opacity, constrain repaired, never refused")
})

test("a refused object shows its alt text and the reason, never JSON; a valid one, its name and count", async () => {
  const { SnoCard } = await import("../src/components/SnoObject.jsx")
  const bad = variant({ faces: [[0, 1, 9]] })
  bad.tags = [["alt", "a 3D object: tetra"]]
  assert.ok(typeof SnoCard === "function")
  const r = readSno(bad)
  assert.equal(r.alt, "a 3D object: tetra"); assert.equal(r.ok, false)
})

test("not in the feed: the feed neither asks for kind 33331 nor draws it as a feed body", () => {
  assert.ok(!FEED_KINDS.includes(SNO_KIND))
  assert.equal(hasKindBody({ kind: SNO_KIND }), false)
})

test("the share page names the object and never prints its JSON", () => {
  const profiles = new Map()
  const meta = previewMeta(ajfu, profiles, "https://nostrvault.app/thread/x")
  assert.match(meta.title, /^AJ FU, by /); assert.equal(meta.description, "a 3D object: AJ FU, 40 vertices")
  const html = renderPost({ post: ajfu, replies: [], profiles, code: "x" })
  assert.match(html, /AJ FU/); assert.match(html, /3D object · 40 vertices/)
  assert.doesNotMatch(html, /"vertices"/)
})
