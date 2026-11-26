// Shrinks a photo before it's uploaded, as the iPhone's ImageCompressor does (Services/MediaCompression/
// ImageCompressor.swift; RESEARCH/NV_UPLOAD_COMPRESSION_2026_11_26.md §4.1 with Logen's 2048 px call, §6).
//
// - "standard" (notes, live chat): long edge at most 2048 px, never upscaled, turned the right way up, JPEG at quality
//   0.82. Redrawing writes no metadata at all (no GPS, camera, serial or date). A JPEG that is already small enough
//   goes up byte for byte. A PNG stays PNG (screenshots, transparency), only resized. A transparent WebP becomes a PNG
//   (a JPEG would paint the clear parts). GIFs and animated WebPs are left alone.
// - "original": the bytes as they are.
// Either way upload.js still takes the location out (media-privacy.js), so it never goes up.
//
// A photo this browser can't draw (HEIC in Chrome or Firefox) goes up as it is, as before. Covers, listings, profile
// photos and DM photos use jpegOf with their own sizes (the iPhone's coverJPEG and ProfileEditView.jpeg). The Media tab
// (Vault › Media, BlossomUpload.jsx) never comes here: it keeps your originals (Logen 2026-11-26).

export const STANDARD_MAX_EDGE = 2048
export const STANDARD_QUALITY = 0.82
/** A JPEG at or under this size, already small enough in pixels, isn't worth redrawing (ImageCompressor.keepAsIsBytes). */
export const KEEP_AS_IS_BYTES = 1_500_000
/** Covers and listings (LongFormComposeView.coverJPEG): 2400 px, 0.8. */
export const COVER = { maxEdge: 2400, quality: 0.8 }
/** Profile picture and banner (ProfileEditView): 1024 px / 2400 px, 0.88. */
export const PROFILE_PICTURE = { maxEdge: 1024, quality: 0.88 }
export const PROFILE_BANNER = { maxEdge: 2400, quality: 0.88 }

/** The drawn size: the long edge brought down to `max`, never up. */
export function fitSize(width, height, max) {
  const long = Math.max(width, height)
  if (!(long > max)) return { width, height }
  const s = max / long
  return { width: Math.max(1, Math.round(width * s)), height: Math.max(1, Math.round(height * s)) }
}

const ascii = (b, at, n) => String.fromCharCode(...b.subarray(at, at + n))

/**
 * What a file is, from its own first bytes, never its type or name (a browser takes the type from the name):
 * { format: "jpeg" | "png" | "gif" | "webp" | "heic" | "other", animated, alpha }. `alpha` is only known for WebP
 * (VP8X's flag, or a VP8L that says it has one); a PNG keeps its own format either way.
 */
export function sniff(b) {
  const out = { format: "other", animated: false, alpha: false }
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) out.format = "jpeg"
  else if (b.length >= 8 && b[0] === 0x89 && ascii(b, 1, 3) === "PNG") {
    out.format = "png"
    out.animated = findPngChunk(b, "acTL") // an APNG
  } else if (b.length >= 4 && ascii(b, 0, 4) === "GIF8") { out.format = "gif"; out.animated = true }
  else if (b.length >= 16 && ascii(b, 0, 4) === "RIFF" && ascii(b, 8, 4) === "WEBP") {
    out.format = "webp"
    const chunk = ascii(b, 12, 4)
    if (chunk === "VP8X" && b.length >= 21) { out.alpha = !!(b[20] & 0x10); out.animated = !!(b[20] & 0x02) }
    else if (chunk === "VP8L" && b.length >= 25) out.alpha = !!(b[24] & 0x10)
  } else if (b.length >= 12 && ascii(b, 4, 4) === "ftyp" && /^(heic|heix|heim|heis|hevc|hevx|mif1|msf1|avif)$/.test(ascii(b, 8, 4))) out.format = "heic"
  return out
}

function findPngChunk(b, name) {
  let at = 8
  while (at + 8 <= b.length) {
    const len = ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0
    const type = ascii(b, at + 4, 4)
    if (type === name) return true
    if (type === "IDAT" || type === "IEND") return false
    at += 12 + len
  }
  return false
}

/**
 * The rules of §4.1, free of the canvas so they can be tested alone (ImageCompressor.plan).
 * -> "keep", or { type: "image/jpeg" | "image/png", maxEdge, quality? }.
 */
export function plan({ format, animated, alpha, width, height, size, quality = "standard" }) {
  if (quality === "original" || animated || format === "gif" || format === "other") return "keep"
  const long = Math.max(width || 0, height || 0)
  if (!(long > 0)) return "keep"
  if (format === "png") return long > STANDARD_MAX_EDGE ? { type: "image/png", maxEdge: STANDARD_MAX_EDGE } : "keep"
  if (alpha) return { type: "image/png", maxEdge: STANDARD_MAX_EDGE }
  if (format === "jpeg" && long <= STANDARD_MAX_EDGE && size <= KEEP_AS_IS_BYTES) return "keep"
  return { type: "image/jpeg", maxEdge: STANDARD_MAX_EDGE, quality: STANDARD_QUALITY }
}

const renamed = (file, type) => (file.name || "photo").replace(/\.[^.]*$/, "") + (type === "image/png" ? ".png" : ".jpg")

/** The photo to upload for `file` at `quality` ("standard" | "original"): a new File when it was redrawn, else `file`
 *  itself. Never throws: anything that isn't a photo, or that this browser can't draw, comes back as it is.
 *  `decode` / `draw` are for tests. */
export async function compressImage(file, { quality = "standard", decode = decodeImage, draw = drawImage } = {}) {
  if (!file || quality === "original" || (file.type && !/^image\//.test(file.type))) return file
  let head
  try { head = sniff(new Uint8Array(await file.slice(0, 4096).arrayBuffer())) } catch { return file }
  if (head.format === "gif" || head.format === "other" || head.animated) return file
  let bmp
  try { bmp = await decode(file) } catch { return file }
  try {
    const p = plan({ ...head, width: bmp.width, height: bmp.height, size: file.size, quality })
    if (p === "keep") return file
    const blob = await draw(bmp, p)
    if (!blob) return file
    return new File([blob], renamed(file, p.type), { type: p.type })
  } catch { return file } finally { bmp.close?.() }
}

/** Any photo as an upright JPEG with no metadata, long edge at most `maxEdge` (covers, listings, profile photos, DM
 *  photos). Throws when the browser can't draw it; callers decide what that means. `decode` / `draw` are for tests. */
export async function jpegOf(file, { maxEdge, quality }, { decode = decodeImage, draw = drawImage } = {}) {
  const bmp = await decode(file)
  try {
    const blob = await draw(bmp, { type: "image/jpeg", maxEdge, quality })
    if (!blob) throw new Error("Couldn't draw that photo.")
    return new File([blob], renamed(file, "image/jpeg"), { type: "image/jpeg" })
  } finally { bmp.close?.() }
}

/** jpegOf, or the file as it is when the browser can't draw it (a HEIC in Chrome): what a cover, listing or profile
 *  photo did before this, so nothing that uploaded yesterday stops uploading. */
export async function jpegOrAsIs(file, size, deps) {
  if (!file || (file.type && !/^image\//.test(file.type))) return file
  try {
    const head = sniff(new Uint8Array(await file.slice(0, 4096).arrayBuffer()))
    if (head.format === "gif" || head.animated) return file // a GIF avatar keeps moving; upload.js still cleans it
    return await jpegOf(file, size, deps)
  } catch { return file }
}

export function decodeImage(file) {
  return createImageBitmap(file, { imageOrientation: "from-image" })
}

/** Draws a decoded photo at its fitted size. A JPEG gets a white ground (a transparent part turns white, not black). */
export function drawImage(bmp, { type, maxEdge, quality }) {
  const { width, height } = fitSize(bmp.width, bmp.height, maxEdge)
  const canvas = typeof OffscreenCanvas === "function" ? new OffscreenCanvas(width, height) : Object.assign(document.createElement("canvas"), { width, height })
  const g = canvas.getContext("2d")
  g.imageSmoothingEnabled = true
  g.imageSmoothingQuality = "high"
  if (type === "image/jpeg") { g.fillStyle = "#fff"; g.fillRect(0, 0, width, height) }
  g.drawImage(bmp, 0, 0, width, height)
  if (canvas.convertToBlob) return canvas.convertToBlob({ type, quality })
  return new Promise(res => canvas.toBlob(res, type, quality))
}
