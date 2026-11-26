// Photos shrunk before they're uploaded (net/image-compress.js, the iPhone's ImageCompressor rules, Logen's 2048 px
// call). The canvas is stubbed: node has none, and what matters here is which bytes reach the upload.
import test from "node:test"
import assert from "node:assert/strict"
import { compressImage, fitSize, jpegOf, jpegOrAsIs, plan, sniff, COVER, KEEP_AS_IS_BYTES, PROFILE_PICTURE, STANDARD_MAX_EDGE, STANDARD_QUALITY } from "../src/net/image-compress.js"

const bytes = (...parts) => new Uint8Array(parts.flatMap(p => typeof p === "string" ? [...p].map(c => c.charCodeAt(0)) : p))
const JPEG = bytes([0xff, 0xd8, 0xff, 0xe1], "Exif GPS 51.5,-0.1")
const PNG = bytes([0x89], "PNG\r\n\x1a\n", [0, 0, 0, 13], "IHDR", new Array(17).fill(0), [0, 0, 0, 0], "IDAT")
const APNG = bytes([0x89], "PNG\r\n\x1a\n", [0, 0, 0, 13], "IHDR", new Array(17).fill(0), [0, 0, 0, 8], "acTL", new Array(12).fill(0))
const webp = flags => bytes("RIFF", [0, 0, 0, 0], "WEBPVP8X", [10, 0, 0, 0, flags, 0, 0, 0])
const HEIC = bytes([0, 0, 0, 24], "ftypheic", [0, 0, 0, 0])
const file = (b, name, type, size) => { const f = new File([b], name, { type }); if (size) Object.defineProperty(f, "size", { value: size }); return f }
const bmp = (width, height) => ({ width, height, closed: false, close() { this.closed = true } })

test("a file is known by its first bytes, never its name or type", () => {
  assert.equal(sniff(JPEG).format, "jpeg")
  assert.deepEqual(sniff(PNG), { format: "png", animated: false, alpha: false })
  assert.equal(sniff(APNG).animated, true)
  assert.deepEqual(sniff(bytes("GIF89a")), { format: "gif", animated: true, alpha: false })
  assert.deepEqual(sniff(webp(0x10)), { format: "webp", animated: false, alpha: true })
  assert.equal(sniff(webp(0x02)).animated, true)
  assert.equal(sniff(HEIC).format, "heic")
  assert.equal(sniff(bytes("%PDF-1.7")).format, "other")
})

test("the rules: 2048 px JPEG at 0.82; small JPEGs, GIFs, animations and Original kept; PNG stays PNG", () => {
  const jpeg = { type: "image/jpeg", maxEdge: STANDARD_MAX_EDGE, quality: STANDARD_QUALITY }
  assert.equal(STANDARD_MAX_EDGE, 2048); assert.equal(STANDARD_QUALITY, 0.82)
  assert.deepEqual(plan({ format: "jpeg", width: 8064, height: 6048, size: 9e6 }), jpeg, "a 48 MP photo")
  assert.deepEqual(plan({ format: "jpeg", width: 2048, height: 1536, size: KEEP_AS_IS_BYTES + 1 }), jpeg, "small in pixels, big in bytes")
  assert.equal(plan({ format: "jpeg", width: 2048, height: 1536, size: KEEP_AS_IS_BYTES }), "keep")
  assert.equal(plan({ format: "jpeg", width: 8064, height: 6048, size: 9e6, quality: "original" }), "keep")
  assert.deepEqual(plan({ format: "heic", width: 4032, height: 3024, size: 2e6 }), jpeg, "a HEIC the browser can draw")
  assert.deepEqual(plan({ format: "webp", width: 1000, height: 800, size: 1e5 }), jpeg, "an opaque WebP is redrawn")
  assert.deepEqual(plan({ format: "webp", alpha: true, width: 1000, height: 800, size: 1e5 }), { type: "image/png", maxEdge: 2048 })
  assert.deepEqual(plan({ format: "png", width: 3000, height: 2000, size: 5e6 }), { type: "image/png", maxEdge: 2048 })
  assert.equal(plan({ format: "png", width: 1170, height: 2532 - 500, size: 5e6 }), "keep", "a screenshot that already fits")
  assert.equal(plan({ format: "gif", width: 4000, height: 4000, size: 9e6 }), "keep")
  assert.equal(plan({ format: "webp", animated: true, width: 4000, height: 4000, size: 9e6 }), "keep")
  assert.equal(plan({ format: "jpeg", width: 0, height: 0, size: 9e6 }), "keep")
  assert.deepEqual(fitSize(8064, 6048, 2048), { width: 2048, height: 1536 })
  assert.deepEqual(fitSize(800, 600, 2048), { width: 800, height: 600 }, "never upscaled")
})

test("a big photo is replaced by the redrawn JPEG, so its own bytes (and EXIF) never go up", async () => {
  const original = file(JPEG, "IMG_0001.jpeg", "image/jpeg", 9e6)
  const b = bmp(8064, 6048)
  let asked
  const out = await compressImage(original, { decode: async () => b, draw: async (_, p) => { asked = p; return new Blob(["clean"], { type: p.type }) } })
  assert.deepEqual(asked, { type: "image/jpeg", maxEdge: 2048, quality: 0.82 })
  assert.equal(out.name, "IMG_0001.jpg"); assert.equal(out.type, "image/jpeg"); assert.equal(await out.text(), "clean")
  assert.equal(b.closed, true, "the decoded bitmap is let go")
})

test("kept as they are: Original, a small JPEG, a GIF, a video, and anything the browser can't draw", async () => {
  const never = async () => { throw new Error("should not draw") }
  const big = file(JPEG, "a.jpg", "image/jpeg", 9e6)
  assert.equal(await compressImage(big, { quality: "original", decode: never, draw: never }), big)
  const small = file(JPEG, "b.jpg", "image/jpeg", 400_000)
  assert.equal(await compressImage(small, { decode: async () => bmp(1600, 1200), draw: never }), small)
  const gif = file(bytes("GIF89a"), "c.gif", "image/gif", 9e6)
  assert.equal(await compressImage(gif, { decode: never, draw: never }), gif)
  const video = file(bytes([0, 0, 0, 24], "ftypisom"), "d.mp4", "video/mp4", 9e7)
  assert.equal(await compressImage(video, { decode: never, draw: never }), video)
  const heic = file(HEIC, "IMG.HEIC", "image/heic", 3e6)
  assert.equal(await compressImage(heic, { decode: async () => { throw new Error("no HEIC here") }, draw: never }), heic, "Chrome can't draw HEIC")
  assert.equal(await compressImage(big, { decode: async () => bmp(8064, 6048), draw: async () => { throw new Error("canvas lost") } }), big)
})

test("covers, listings and profile photos: an upright JPEG at their own size; one the browser can't draw goes as it is", async () => {
  let asked
  const out = await jpegOf(file(PNG, "cover.png", "image/png"), COVER, { decode: async () => bmp(4000, 3000), draw: async (_, p) => { asked = p; return new Blob(["j"]) } })
  assert.deepEqual(asked, { type: "image/jpeg", maxEdge: 2400, quality: 0.8 })
  assert.equal(out.name, "cover.jpg")
  await jpegOrAsIs(file(JPEG, "me.jpg", "image/jpeg"), PROFILE_PICTURE, { decode: async () => bmp(3000, 3000), draw: async (_, p) => { asked = p; return new Blob(["j"]) } })
  assert.deepEqual(asked, { type: "image/jpeg", maxEdge: 1024, quality: 0.88 })
  const heic = file(HEIC, "me.heic", "image/heic")
  assert.equal(await jpegOrAsIs(heic, PROFILE_PICTURE, { decode: async () => { throw new Error("x") } }), heic)
  const gif = file(bytes("GIF89a"), "me.gif", "image/gif")
  assert.equal(await jpegOrAsIs(gif, PROFILE_PICTURE), gif, "a moving avatar keeps moving")
})
