// Removes where a photo or video was taken before it is uploaded, as the iPhone does (Services/MediaPrivacy.swift). A
// Blossom blob is public and content-addressed: once a mirror has it, a GPS fix in it cannot be taken back.
//
// Only a file that carries a location is changed, so an ordinary photo uploads byte for byte. The change is done in
// place and keeps every length, so nothing is re-encoded and no container offset moves:
//   - EXIF (JPEG APP1, its MPF second images, HEIC's Exif item, WebP's EXIF chunk, PNG's eXIf): the GPS IFD's values
//     and entries are zeroed and the GPS pointer is taken out of IFD0. The rest (orientation, camera, date) stays.
//   - XMP (any of those containers, and inside a video's moov): exif:GPS* properties become spaces.
//   - MP4/MOV: the ©xyz and loci boxes, and a metadata box whose keys name a location, become zeroed "free" boxes.
// Then the result is read again; a file that still has a location is not uploaded ("never send a location").
// A container this can't read (WebM, MKV, GIF) goes up as it is, as on the iPhone.

/** Shown when a file has a location that could not be removed (MediaPrivacy.failureMessage). */
export const LOCATION_FAILURE = "Couldn't remove the location from this file, so it wasn't uploaded."

const ascii = s => Array.from(s, c => c.charCodeAt(0))
const EXIF = ascii("Exif\0\0")
const XMP_OPEN = ascii("<x:xmpmeta"), XMP_CLOSE = ascii("</x:xmpmeta>")
const LOCATION_KEY = ascii("location")

function indexOf(b, needle, from = 0, to = b.length) {
  const first = needle[0], last = to - needle.length
  outer: for (let i = b.indexOf(first, from); i !== -1 && i <= last; i = b.indexOf(first, i + 1)) {
    for (let j = 1; j < needle.length; j++) if (b[i + j] !== needle[j]) continue outer
    return i
  }
  return -1
}
const type4 = (b, at) => String.fromCharCode(b[at], b[at + 1], b[at + 2], b[at + 3])
const u32be = (b, at) => ((b[at] << 24) >>> 0) + (b[at + 1] << 16) + (b[at + 2] << 8) + b[at + 3]
const u32le = (b, at) => b[at] + (b[at + 1] << 8) + (b[at + 2] << 16) + ((b[at + 3] << 24) >>> 0)

// ---- EXIF (TIFF) ----

const TYPE_SIZE = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4]
const GPS_POINTER = 0x8825

/** The GPS of the TIFF block at `t`: found? With `fix`, its values and entries are zeroed and IFD0 stops pointing at
 *  it. Every offset is checked against `end`; a block that doesn't parse is reported as no GPS. */
function tiffGps(b, t, end, fix) {
  if (t + 8 > end) return false
  const le = b[t] === 0x49 && b[t + 1] === 0x49
  if (!le && !(b[t] === 0x4d && b[t + 1] === 0x4d)) return false
  const u16 = at => le ? b[at] | (b[at + 1] << 8) : (b[at] << 8) | b[at + 1]
  const u32 = at => le ? u32le(b, at) : u32be(b, at)
  if (u16(t + 2) !== 42) return false
  const ifd0 = t + u32(t + 4)
  if (ifd0 + 2 > end) return false
  const n = u16(ifd0)
  if (ifd0 + 2 + n * 12 + 4 > end) return false
  let at = -1
  for (let i = 0; i < n; i++) if (u16(ifd0 + 2 + i * 12) === GPS_POINTER) { at = i; break }
  if (at < 0) return false
  if (!fix) return true
  const gps = t + u32(ifd0 + 2 + at * 12 + 8)
  if (gps + 2 <= end) {
    const m = u16(gps)
    if (gps + 2 + m * 12 + 4 <= end) {
      for (let i = 0; i < m; i++) {
        const e = gps + 2 + i * 12, size = (TYPE_SIZE[u16(e + 2)] ?? 0) * u32(e + 4)
        if (size > 4) { const v = t + u32(e + 8); if (v >= t && v + size <= end) b.fill(0, v, v + size) }
      }
      b.fill(0, gps, gps + 2 + m * 12 + 4)
    }
  }
  // IFD0 without the pointer: the entries after it (and the next-IFD offset) move up one slot.
  const entry = ifd0 + 2 + at * 12, stop = ifd0 + 2 + n * 12 + 4
  b.copyWithin(entry, entry + 12, stop)
  b.fill(0, stop - 12, stop)
  if (le) { b[ifd0] = (n - 1) & 0xff; b[ifd0 + 1] = (n - 1) >> 8 } else { b[ifd0] = (n - 1) >> 8; b[ifd0 + 1] = (n - 1) & 0xff }
  return true
}

/** Every "Exif\0\0" block in the file: a JPEG's APP1 and the second images MPF appends, HEIC's Exif item, WebP. */
function exifBlocks(b, fix) {
  let found = 0
  for (let i = indexOf(b, EXIF); i !== -1; i = indexOf(b, EXIF, i + 6)) if (tiffGps(b, i + 6, b.length, fix)) found++
  return found
}

// ---- XMP ----

const XMP_GPS = [/\bexif(?:EX)?:GPS\w*\s*=\s*(?:"[^"]*"|'[^']*')/g, /<(exif(?:EX)?:GPS\w*)\b[^>]*?(?:\/>|>[\s\S]*?<\/\1\s*>)/g]

/** exif:GPS* in every XMP packet between `from` and `to`; with `fix` each becomes spaces of the same length. */
function xmpGps(b, fix, from = 0, to = b.length) {
  let found = 0
  for (let s = indexOf(b, XMP_OPEN, from, to); s !== -1; s = indexOf(b, XMP_OPEN, s + 1, to)) {
    const close = indexOf(b, XMP_CLOSE, s, to)
    const e = close === -1 ? to : close
    let text = ""
    for (let i = s; i < e; i += 8192) text += String.fromCharCode.apply(null, b.subarray(i, Math.min(e, i + 8192)))
    for (const re of XMP_GPS) {
      for (const m of text.matchAll(re)) { found++; if (fix) b.fill(0x20, s + m.index, s + m.index + m[0].length) }
    }
  }
  return found
}

// ---- PNG ----

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
let crcTable
function crc32(b, from, to) {
  if (!crcTable) {
    crcTable = new Uint32Array(256)
    for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; crcTable[n] = c >>> 0 }
  }
  let c = 0xffffffff
  for (let i = from; i < to; i++) c = crcTable[(c ^ b[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

/** PNG eXIf (a bare TIFF) and XMP in iTXt. Fixed chunks get their CRC again. A compressed XMP chunk can't be read
 *  here, so it is reported as a location and left: the file then isn't uploaded. */
function pngGps(b, fix) {
  let found = 0
  for (let at = 8; at + 12 <= b.length;) {
    const len = u32be(b, at), type = type4(b, at + 4), data = at + 8, end = data + len
    if (end + 4 > b.length) break
    let hit = 0
    if (type === "eXIf") hit = tiffGps(b, data, end, fix) ? 1 : 0
    else if (type === "iTXt" || type === "zTXt" || type === "tEXt") {
      const compressed = type === "zTXt" || (type === "iTXt" && b[indexOf(b, [0], data, end) + 1] === 1)
      if (compressed && indexOf(b, ascii("XML:com.adobe.xmp"), data, end) === data) found++
      else hit = xmpGps(b, fix, data, end)
    }
    if (hit && fix) {
      const c = crc32(b, at + 4, end)
      b[end] = c >>> 24; b[end + 1] = (c >>> 16) & 0xff; b[end + 2] = (c >>> 8) & 0xff; b[end + 3] = c & 0xff
    }
    found += hit
    if (type === "IEND") break
    at = end + 4
  }
  return found
}

// ---- WebP ----

/** A WebP's EXIF chunk is usually a bare TIFF (Exif\0\0-prefixed ones are found by exifBlocks). */
function webpGps(b, fix) {
  let found = 0
  for (let at = 12; at + 8 <= b.length;) {
    const type = type4(b, at), len = u32le(b, at + 4), data = at + 8, end = Math.min(b.length, data + len)
    if (type === "EXIF" && tiffGps(b, data, end, fix)) found++
    at = data + len + (len & 1)
  }
  return found
}

// ---- MP4 / MOV ----

const CONTAINERS = new Set(["moov", "trak", "udta", "meta", "mdia", "minf", "ilst"])

/** Location boxes inside `moov`: ©xyz, 3GPP loci, and a metadata box whose keys name a location (Apple's
 *  com.apple.quicktime.location.ISO6709). Fixing zeroes each and renames it "free", which every reader skips. */
function bmffGps(b, fix, from = 0, to = b.length, inMoov = false) {
  let found = 0
  for (let at = from; at + 8 <= to;) {
    let size = u32be(b, at), head = 8
    const type = type4(b, at + 4)
    if (size === 1) { if (at + 16 > to) break; size = u32be(b, at + 8) * 2 ** 32 + u32be(b, at + 12); head = 16 }
    else if (size === 0) size = to - at
    if (size < head || at + size > to) break
    const end = at + size
    const free = () => { found++; if (fix) { b.set(ascii("free"), at + 4); b.fill(0, at + head, end) } }
    if (inMoov && (type === "©xyz" || type === "loci")) free()
    else if (inMoov && type === "meta" && indexOf(b, LOCATION_KEY, at, end) !== -1) free()
    else if (type === "moov" || (inMoov && CONTAINERS.has(type))) {
      // An MP4 meta is a full box (4 bytes of version and flags first); a QuickTime meta starts with its children.
      const kids = type === "meta" && type4(b, at + head + 4) !== "hdlr" ? at + head + 4 : at + head
      found += bmffGps(b, fix, kids, end, true)
      if (type === "moov") found += xmpGps(b, fix, at, end)
    }
    at = end
  }
  return found
}

// ----

function locations(b, fix) {
  let found = exifBlocks(b, fix)
  if (indexOf(b, PNG_SIG, 0, 8) === 0) return found + pngGps(b, fix)
  if (type4(b, 0) === "RIFF" && type4(b, 8) === "WEBP") found += webpGps(b, fix)
  if (type4(b, 4) === "ftyp") found += bmffGps(b, fix)
  if (type4(b, 4) !== "ftyp" || b.length < 64e6) found += xmpGps(b, fix) // a video's XMP is read inside its moov
  return found
}

/** Whether these bytes carry a location this module can find. */
export const hasLocation = bytes => locations(bytes, false) > 0

/** The bytes to upload: `bytes` itself when it carries no location, a copy without it when it did. Throws
 *  LOCATION_FAILURE when a location is there and could not be removed. */
export function withoutLocation(bytes) {
  if (!hasLocation(bytes)) return bytes
  const out = bytes.slice()
  locations(out, true)
  if (hasLocation(out)) throw new Error(LOCATION_FAILURE)
  return out
}
