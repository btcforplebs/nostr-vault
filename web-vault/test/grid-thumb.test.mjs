// Media grid tiles (media perf review 2026-11-28, findings 1-2): a photo tile draws the note's imeta `thumb`, else the
// original; a video tile draws a poster or nothing, never the video, so no video bytes load until the note is opened.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { imetaPreview, photoThumb, videoPoster } from "../src/components/grid-thumb.js"

const P = "https://b.example/" + "a".repeat(64) + ".jpg"
const V = "https://b.example/" + "b".repeat(64) + ".mp4"
const T = "https://b.example/" + "c".repeat(64) + ".webp"
const I = "https://b.example/" + "d".repeat(64) + ".jpg"

test("a photo with an imeta thumb draws the thumb", () => {
  const tags = [["imeta", `url ${P}`, "m image/jpeg", `thumb ${T}`, `image ${I}`]]
  assert.equal(photoThumb(P, tags), T)
})

test("no thumb, no imeta, another url's imeta, or no tags: the original (undefined)", () => {
  assert.equal(photoThumb(P, [["imeta", `url ${P}`, "m image/jpeg", `image ${I}`]]), undefined, "image is full size: no saving")
  assert.equal(photoThumb(P, [["imeta", `url ${V}`, `thumb ${T}`]]), undefined)
  assert.equal(photoThumb(P, [["e", "x"]]), undefined)
  assert.equal(photoThumb(P, undefined), undefined)
})

test("web thumbs only: a .fips one, a thumb equal to the url, or junk is left out", () => {
  assert.equal(photoThumb(P, [["imeta", `url ${P}`, "thumb http://b.example/t.jpg"]]), "http://b.example/t.jpg")
  const fips = "http://npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsdsx4h.fips/" + "c".repeat(64)
  for (const bad of [fips, P, "javascript:alert(1)", "ftp://b.example/t.jpg", ""])
    assert.equal(photoThumb(P, [["imeta", `url ${P}`, `thumb ${bad}`]]), undefined, bad)
})

test("the first imeta for a url and the first of each field win", () => {
  const tags = [["imeta", `url ${P}`, `thumb ${T}`, `thumb ${I}`], ["imeta", `url ${P}`, `thumb ${I}`]]
  assert.deepEqual(imetaPreview(P, tags), { thumb: T })
})

test("a video's poster: thumb, else image, else none", () => {
  assert.equal(videoPoster(V, [["imeta", `url ${V}`, "m video/mp4", `thumb ${T}`, `image ${I}`]]), T)
  assert.equal(videoPoster(V, [["imeta", `url ${V}`, "m video/mp4", `image ${I}`]]), I)
  assert.equal(videoPoster(V, [["imeta", `url ${V}`, "m video/mp4"]]), undefined)
})

test("the grid never draws a <video> tile, and both grids go through GridPhoto", () => {
  const grid = readFileSync(new URL("../src/components/MediaGrid.jsx", import.meta.url), "utf8")
  assert.doesNotMatch(grid, /<video/)
  assert.match(grid, /<GridPhoto item=\{imageItem\(t\.url, t\.note\?\.tags\)\} thumb=\{photoThumb\(/)
  const vault = readFileSync(new URL("../src/screens/VaultScreen.jsx", import.meta.url), "utf8")
  assert.match(vault, /class="vault-thumb"><GridPhoto item=\{p\.item\} thumb=\{photoThumb\(p\.url, tagsOf\.get\(p\.noteId\)\)\}/)
})
