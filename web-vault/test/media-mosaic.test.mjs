// Vault › Media as a mosaic (net/media-mosaic.js, the web twin of Apple's MediaMosaicLayout, PR 2193): each file keeps
// its shape, dealt to the shortest column, sized before it loads from a learned shape or a `dim`, square otherwise;
// the media napplet's copy answers the same.
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import vm from "node:vm"
import { aspectFromDim, clampAspect, columnsFor, deal, flush, learnShape, shapeOf, shapesNow, _resetShapes } from "../src/net/media-mosaic.js"
import { mergeNoteTiles, nip94Dim } from "../src/net/blossom-gallery.js"
import { parseFileNote } from "../src/net/file-notes.js"

const H = c => c.repeat(64)
const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), m } }

test("shapes: dim parsed, clamped to 1:2 .. 2:1, square when unknown", () => {
  assert.equal(aspectFromDim("1920x1080"), 1920 / 1080)
  assert.equal(aspectFromDim("1080X1920"), 1080 / 1920)
  for (const bad of ["", "0x100", "100x0", "abc", "100", null, undefined, 5]) assert.equal(aspectFromDim(bad), null, String(bad))
  assert.equal(clampAspect(5), 2); assert.equal(clampAspect(0.1), 0.5); assert.equal(clampAspect(1.5), 1.5)
  for (const x of [null, undefined, NaN, 0, -1, Infinity]) assert.equal(clampAspect(x), 1, String(x))
})

test("columns: 3 on a phone, more as the grid widens, at most 6", () => {
  assert.deepEqual([320, 430, 599, 600, 899, 900, 1199, 1200, 2400].map(columnsFor), [3, 3, 3, 4, 4, 5, 5, 6, 6])
})

test("deal: each to the shortest column, ties to the left, order kept, adding at the end moves nothing", () => {
  const items = [["a", 1], ["b", 1], ["c", 1], ["d", 0.5], ["e", 2], ["f", 1], ["g", 2]]
  const cols = deal(items, 3, x => x[1]).map(c => c.map(x => x[0]))
  assert.deepEqual(cols[0].slice(0, 1).concat(cols[1].slice(0, 1), cols[2].slice(0, 1)), ["a", "b", "c"], "the first row reads across")
  assert.deepEqual(cols, [["a", "d"], ["b", "e", "g"], ["c", "f"]])
  const more = deal([...items, ["h", 1], ["i", 1]], 3, x => x[1]).map(c => c.map(x => x[0]))
  for (let i = 0; i < 3; i++) assert.deepEqual(more[i].slice(0, cols[i].length), cols[i], "earlier tiles stay where they were")
  assert.deepEqual(deal([], 4, () => 1), [[], [], [], []])
})

test("learned shapes: saved in batches, read when a grid goes up, never past the cap", () => {
  _resetShapes()
  const s = store()
  assert.equal(shapesNow(s).size, 0)
  learnShape(H("a"), 400, 300, s); learnShape("nope", 400, 300, s); learnShape(H("b"), 0, 300, s)
  assert.equal(shapesNow(s).get(H("a")), 1.333, "a waiting one counts for the next grid")
  flush(s)
  assert.deepEqual(JSON.parse(s.getItem("nv-media-shapes")), { [H("a")]: 1.333 })
  assert.equal(shapeOf({ sha256: H("a"), dim: "100x100" }, shapesNow(s)), 1.333, "learned before dim")
  assert.equal(shapeOf({ sha256: H("c"), dim: "300x600" }, shapesNow(s)), 0.5)
  assert.equal(shapeOf({ sha256: H("c") }, shapesNow(s)), null)
  for (let i = 0; i < 3005; i++) learnShape(i.toString(16).padStart(64, "0"), 2, 1, s)
  flush(s)
  assert.equal(Object.keys(JSON.parse(s.getItem("nv-media-shapes"))).length, 3000)
  s.setItem("nv-media-shapes", "[1,2]"); assert.equal(shapesNow(s).size, 0, "junk in storage reads as nothing")
  _resetShapes()
})

test("dim from a server's NIP-94 descriptor (tags or object) and from file notes", () => {
  assert.equal(nip94Dim([["url", "x"], ["dim", "640x480"]]), "640x480")
  assert.equal(nip94Dim({ dim: "640x480" }), "640x480")
  assert.equal(nip94Dim([["dim", "640 by 480"]]), undefined)
  assert.equal(nip94Dim(undefined), undefined)
  const ev = { kind: 1063, id: "i1", pubkey: H("1"), created_at: 5, tags: [["x", H("a")], ["m", "image/jpeg"], ["size", "10"], ["p", H("2")], ["url", "https://s.example/a.jpg"], ["dim", "1080x1920"]] }
  assert.equal(parseFileNote(ev).dim, "1080x1920")
  assert.equal("dim" in parseFileNote({ ...ev, tags: ev.tags.filter(t => t[0] !== "dim") }), false, "no dim: the row is as before")
  assert.equal("dim" in parseFileNote({ ...ev, tags: [...ev.tags.filter(t => t[0] !== "dim"), ["dim", "<b>"]] }), false)
  const blobs = [{ sha256: H("a"), url: "https://s.example/a.jpg", servers: ["s"], uploaded: 5, kind: "photo" }]
  const merged = mergeNoteTiles(blobs, [{ sha256: H("a"), urls: ["https://s.example/a.jpg"], mime: "image/jpeg", size: 10, createdAt: 5, dim: "1080x1920" }])
  assert.equal(merged[0].dim, "1080x1920", "a listed file takes its note's size")
  assert.equal(mergeNoteTiles(blobs, []), blobs, "nothing to add: the same list")
})

test("the media napplet's mosaic answers as the app's", () => {
  const html = fs.readFileSync(new URL("../napplets/media/index.html", import.meta.url), "utf8")
  const box = {}
  vm.runInNewContext(`${html.slice(html.indexOf("// ---- pure"), html.indexOf("// ---- end pure ----"))}\n;Object.assign(box, { deal, columnsFor, clampAspect, aspectFromDim, nip94Dim, mergeLists, withNoteTiles })`, { box, Date, URL })
  let seed = 3; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  const items = Array.from({ length: 200 }, (_, i) => ({ i, a: rnd() < 0.2 ? null : 0.3 + rnd() * 2.5 }))
  const plain = x => JSON.parse(JSON.stringify(x))
  for (const k of [3, 4, 5, 6]) assert.deepEqual(plain(box.deal(items, k, x => x.a).map(c => c.map(x => x.i))), deal(items, k, x => x.a).map(c => c.map(x => x.i)))
  for (const w of [320, 700, 1000, 1500]) assert.equal(box.columnsFor(w), columnsFor(w))
  for (const d of ["16x9", "0x1", "x"]) assert.equal(box.aspectFromDim(d), aspectFromDim(d))
  const rows = JSON.parse(JSON.stringify(box.mergeLists([{ server: "https://s.example", blobs: [{ sha256: H("1"), url: "https://s.example/1.jpg", type: "image/jpeg", uploaded: 1, nip94: [["dim", "300x200"]] }] }])))
  assert.equal(rows[0].dim, "300x200")
  const shellRows = JSON.parse(JSON.stringify(box.mergeLists([{ server: "https://s.example", blobs: [{ sha256: H("1"), url: "https://s.example/1.jpg", uploaded: 1, dim: "40x30" }, { sha256: H("2"), url: "https://s.example/2.jpg", uploaded: 0, dim: "4 0x30" }] }])))
  assert.deepEqual(shellRows.map(r => r.dim), ["40x30", undefined], "the shell's rows carry dim; a malformed one is dropped")
  const withTiles = JSON.parse(JSON.stringify(box.withNoteTiles(rows.map(r => ({ ...r, dim: undefined })), [{ sha256: H("1"), url: "https://s.example/1.jpg", dim: "50x100" }, { sha256: H("2"), url: "https://s.example/2.jpg", dim: "bad" }], [])))
  assert.equal(withTiles.find(r => r.sha256 === H("1")).dim, "50x100")
  assert.equal(withTiles.find(r => r.sha256 === H("2")).dim, undefined, "a malformed dim is dropped")
})

test("the gallery's tile sets aspect-ratio as a string (Preact adds px to a number: 1.78px is invalid, every tile square)", () => {
  const src = fs.readFileSync(new URL("../src/screens/BlossomGallery.jsx", import.meta.url), "utf8")
  assert.match(src, /style=\{\{ aspectRatio: String\(aspect\) \}\}/)
  assert.doesNotMatch(src, /aspectRatio: aspect\b/)
})
