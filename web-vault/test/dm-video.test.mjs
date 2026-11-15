// A video in a DM goes locked like a photo (NIP-17 kind 15, Logen 2026-11-15): where it was taken comes out, it is
// refused over 100 MB, encrypted before it goes up, and the thread opens it with its size and how much has arrived.
import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import { MAX_FILE, fileContentOf, parseFileLink, isVideoLink, openFileLink, encryptFile, fileLink, fileMessage } from "../src/net/dm-file.js"
import { prepareVideo, TOO_BIG } from "../src/net/dm-video.js"
import { hasLocation } from "../src/net/media-privacy.js"
import { lastPreview } from "../src/net/dms.js"

const text = s => Array.from(s, c => c.charCodeAt(0))
function box(type, ...parts) {
  const body = parts.flatMap(p => typeof p === "string" ? text(p) : p)
  const size = 8 + body.length
  return [size >>> 24, (size >>> 16) & 0xff, (size >>> 8) & 0xff, size & 0xff, ...text(type), ...body]
}
const ISO = "+40.7128-074.0060+010.000/"
const movie = () => new Uint8Array([
  ...box("ftyp", "qt  ", [0, 0, 0, 0], "qt  "),
  ...box("moov", box("mvhd", new Array(100).fill(0)), box("udta", box("©xyz", [0, ISO.length, 0x15, 0xc7], ISO))),
  ...box("mdat", new Array(64).fill(7)),
])
const vectors = async () => JSON.parse(await readFile(new URL("./fixtures/DM_FILE_VECTORS.json", import.meta.url), "utf8")).vectors

test("a locked file may be up to 100 MB plus its 16-byte tag", () => {
  assert.equal(MAX_FILE, 100 * 1024 * 1024 + 16)
})

test("a tapped open reads a full 100 MB video from the apps (100 MB + 16 bytes of ciphertext)", async () => {
  const enc = await encryptFile(new Uint8Array([1, 2, 3]))
  const link = fileLink("https://b.example/x", { ...enc, mime: "video/mp4" })
  let asked
  await openFileLink(link, { fetchBytes: async (_u, _p, { max }) => { asked = max; return enc.cipher } })
  assert.equal(asked, 100 * 1024 * 1024 + 16)
})

test("a picked video loses its location and keeps its type", async () => {
  const file = new File([movie()], "clip.mov", { type: "video/quicktime" })
  assert.ok(hasLocation(movie()))
  const out = await prepareVideo(file)
  assert.equal(out.type, "video/quicktime")
  assert.equal(hasLocation(new Uint8Array(await out.arrayBuffer())), false)
})

test("a video over 100 MB is refused with a clear message, before it is read", async () => {
  const big = { type: "video/mp4", size: MAX_FILE, name: "big.mp4", arrayBuffer: () => { throw new Error("read") } }
  await assert.rejects(prepareVideo(big), e => e.message === TOO_BIG && /100 MB/.test(e.message))
})

test("only a video is a video", async () => {
  await assert.rejects(prepareVideo(new File([new Uint8Array(4)], "a.png", { type: "image/png" })), /Couldn't read that video/)
})

test("the video vector shows as a video with its size, and opens to an MP4", async () => {
  const v = (await vectors()).find(x => x.id === "mp4-video-12-byte-nonce")
  const kept = fileContentOf(v.rumor)
  assert.ok(isVideoLink(kept))
  assert.equal(parseFileLink(kept).size, v.size)
  assert.equal(lastPreview(kept), "Video")
  const seen = []
  const blob = await openFileLink(kept, { fetchBytes: async (_u, onProgress) => { onProgress?.(v.size, v.size); return Buffer.from(v.ciphertext_hex, "hex") }, onProgress: (got, all) => seen.push([got, all]) })
  assert.equal(blob.type, "video/mp4")
  assert.equal(Buffer.from(await blob.arrayBuffer()).toString("hex"), v.plaintext_hex)
  assert.deepEqual(seen.at(-1), [v.size, v.size])
})

test("a photo link is not a video link; a sent video's link carries its size", async () => {
  const enc = await encryptFile(new Uint8Array([1, 2, 3]))
  const photo = fileLink("https://f.example/" + enc.x, { ...enc, mime: "image/png" })
  assert.equal(isVideoLink(photo), false)
  assert.equal(lastPreview(photo), "Photo")
  const m = fileMessage("https://f.example/" + enc.x, enc, { mime: "video/mp4" })
  assert.ok(isVideoLink(m.shown))
  assert.equal(parseFileLink(m.shown).size, enc.cipher.length)
})

test("an open without a tap is held to AUTO_SHOW_MAX, whatever the size tag says (Tron #2105 M1)", async () => {
  const { AUTO_SHOW_MAX, autoLink } = await import("../src/net/dm-file.js")
  const plain = new Uint8Array(AUTO_SHOW_MAX + 1024)
  const enc = await encryptFile(plain)
  // The sender's size tag says 1000 bytes; the file is bigger than a thread opens by itself.
  const link = fileLink("https://files.example/" + enc.x, { ...enc, mime: "video/mp4", size: 1000 })
  const asked = []
  const fetchBytes = async (url, onProgress, opts) => { asked.push(opts?.max); return enc.cipher }
  await assert.rejects(openFileLink(link, { fetchBytes, max: AUTO_SHOW_MAX }), e => e.tooBig === true)
  assert.equal(asked[0], AUTO_SHOW_MAX)
  // A link marked auto (the Messages napplet, through the shell) is held there too, with no max given.
  await assert.rejects(openFileLink(autoLink(link), { fetchBytes }), e => e.tooBig === true)
  assert.equal(parseFileLink(autoLink(link)).auto, true)
  assert.equal(parseFileLink(link).auto, undefined)
  // A tap opens it whole.
  const blob = await openFileLink(link, { fetchBytes })
  assert.equal(blob.size, plain.length)
})
