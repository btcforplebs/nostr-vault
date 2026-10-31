// Where a photo or video was taken comes out before it is uploaded (Services/MediaPrivacy.swift). The fixtures are real
// files geotagged with exiftool (40°42'46.08"N 74°0'21.6"W, Orientation 6, plus XMP exif:GPSLatitude/Longitude).
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createHash } from "node:crypto"
import { finalizeEvent, generateSecretKey, getPublicKey } from "nostr-tools/pure"
import { LOCATION_FAILURE, hasLocation, withoutLocation } from "../src/net/media-privacy.js"
import { uploadPhoto } from "../src/net/upload.js"

const fixture = name => new Uint8Array(readFileSync(new URL(`./fixtures/location/${name}`, import.meta.url)))
const find = (b, needle) => {
  for (let i = 0; i <= b.length - needle.length; i++) if (needle.every((v, j) => b[i + j] === v)) return i
  return -1
}
const text = s => Array.from(s, c => c.charCodeAt(0))
// 46.08" is stored as the rational 1152/25, in either byte order: proof the seconds themselves are gone.
const SECONDS = [[0, 0, 0x04, 0x80, 0, 0, 0, 0x19], [0x80, 0x04, 0, 0, 0x19, 0, 0, 0]]
const hasSeconds = b => SECONDS.some(s => find(b, s) !== -1)
// IFD0's Orientation entry (tag 0x0112, SHORT, 1, value 6), either byte order.
const ORIENTATION = [[0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6], [0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0]]
const hasOrientation = b => ORIENTATION.some(s => find(b, s) !== -1)

for (const name of ["gps.jpg", "gps.png", "gps.heic"]) {
  test(`${name}: GPS in EXIF and XMP is removed, the length and orientation stay`, () => {
    const b = fixture(name)
    assert.ok(hasLocation(b))
    assert.ok(hasSeconds(b) && find(b, text("GPSLatitude")) !== -1) // the gate can fail
    const out = withoutLocation(b)
    assert.notEqual(out, b)
    assert.equal(out.length, b.length)
    assert.equal(hasLocation(out), false)
    assert.equal(hasSeconds(out), false)
    assert.equal(find(out, text("GPSLatitude")), -1)
    assert.equal(find(out, text("GPSLongitude")), -1)
    assert.ok(hasOrientation(out))
    assert.ok(hasLocation(b), "the original is left as it was")
  })
}

test("a photo with no location uploads byte for byte", () => {
  const b = fixture("clean.jpg")
  assert.equal(hasLocation(b), false)
  assert.equal(withoutLocation(b), b)
})

test("a PNG that was changed still has a valid CRC on every chunk", () => {
  const out = withoutLocation(fixture("gps.png"))
  const crc = (from, to) => {
    let c = 0xffffffff
    for (let i = from; i < to; i++) { c ^= out[i]; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1 }
    return (c ^ 0xffffffff) >>> 0
  }
  const u32 = at => out[at] * 2 ** 24 + (out[at + 1] << 16) + (out[at + 2] << 8) + out[at + 3]
  for (let at = 8; at < out.length;) {
    const len = u32(at), end = at + 8 + len
    assert.equal(u32(end), crc(at + 4, end), `chunk at ${at}`)
    at = end + 4
  }
})

// A QuickTime file as an iPhone writes its location: moov/udta/©xyz and moov/meta keys ISO6709.
function box(type, ...parts) {
  const body = parts.flatMap(p => typeof p === "string" ? text(p) : p)
  const size = 8 + body.length
  return [size >>> 24, (size >>> 16) & 0xff, (size >>> 8) & 0xff, size & 0xff, ...text(type), ...body]
}
const ISO = "+40.7128-074.0060+010.000/"
const movie = () => new Uint8Array([
  ...box("ftyp", "qt  ", [0, 0, 0, 0], "qt  "),
  ...box("moov",
    box("mvhd", new Array(100).fill(0)),
    box("trak", box("tkhd", new Array(84).fill(0))),
    box("udta", box("©xyz", [0, ISO.length, 0x15, 0xc7], ISO)),
    box("meta", box("hdlr", new Array(25).fill(0), "mdta"), box("keys", [0, 0, 0, 0, 0, 0, 0, 1], box("mdta", "com.apple.quicktime.location.ISO6709")),
      box("ilst", box("\u0000\u0000\u0000\u0001", box("data", [0, 0, 0, 1, 0, 0, 0, 0], ISO))))),
  ...box("mdat", new Array(64).fill(7)),
])

test("a video's ©xyz and location metadata become zeroed free boxes; nothing else moves", () => {
  const b = movie()
  assert.ok(hasLocation(b))
  const out = withoutLocation(b)
  assert.equal(out.length, b.length)
  assert.equal(hasLocation(out), false)
  assert.equal(find(out, text("40.7128")), -1)
  assert.equal(find(out, text("ISO6709")), -1)
  assert.equal(find(out, text("©xyz")), -1)
  for (const kept of ["ftyp", "mvhd", "trak", "tkhd", "mdat"]) assert.equal(find(out, text(kept)), find(b, text(kept)), kept)
  assert.deepEqual(out.subarray(find(b, text("mdat"))), b.subarray(find(b, text("mdat"))))
})

test("a location that can't be removed (compressed XMP in a PNG) is not uploaded", () => {
  const clean = withoutLocation(fixture("gps.png")) // a PNG with no location left, then a compressed XMP chunk after IHDR
  const ihdrEnd = 8 + 25
  const chunk = box("iTXt", "XML:com.adobe.xmp", [0, 1, 0, 0, 0], [0x78, 0x9c, 1, 2, 3])
  chunk.push(0, 0, 0, 0)
  const b = new Uint8Array([...clean.subarray(0, ihdrEnd), ...chunk, ...clean.subarray(ihdrEnd)])
  assert.ok(hasLocation(b))
  assert.throws(() => withoutLocation(b), { message: LOCATION_FAILURE })
})

test("uploadPhoto sends the bytes without the location, hashed as sent", async () => {
  const sk = generateSecretKey(), pk = getPublicKey(sk)
  const ctx = { session: { pubkey: pk }, signer: { signEvent: async t => finalizeEvent(t, sk) } }
  const original = fixture("gps.jpg")
  let sent
  const fetch = async (url, init) => {
    sent = init.body
    const sha256 = createHash("sha256").update(init.body).digest("hex")
    return new Response(JSON.stringify({ sha256, url: `https://media.example.com/${sha256}.jpg` }), { status: 200 })
  }
  const r = await uploadPhoto(new File([original], "gps.jpg", { type: "image/jpeg" }), { ctx, servers: ["https://media.example.com"], fetch })
  assert.equal(hasLocation(sent), false)
  assert.equal(hasSeconds(sent), false)
  assert.equal(r.size, original.length)
  assert.equal(r.sha256, createHash("sha256").update(sent).digest("hex"))
  assert.notEqual(r.sha256, createHash("sha256").update(original).digest("hex"))
})

test("uploadPhoto refuses a file whose location can't be removed, before signing anything", async () => {
  const clean = withoutLocation(fixture("gps.png"))
  const chunk = box("zTXt", "XML:com.adobe.xmp", [0, 0], [0x78, 0x9c, 1])
  chunk.push(0, 0, 0, 0)
  const b = new Uint8Array([...clean.subarray(0, 33), ...chunk, ...clean.subarray(33)])
  let signed = 0
  const ctx = { session: { pubkey: "a".repeat(64) }, signer: { signEvent: async () => { signed++ } } }
  await assert.rejects(uploadPhoto(new File([b], "x.png", { type: "image/png" }), { ctx, servers: ["https://media.example.com"], fetch: async () => assert.fail("uploaded") }), { message: LOCATION_FAILURE })
  assert.equal(signed, 0)
})
