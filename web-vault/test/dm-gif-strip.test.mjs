// A GIF in a DM goes up as its frames only (Tron, DM privacy 2026-11-14): comment, XMP, ICC and every other application
// or text block is dropped; the frames, their timing (graphic control) and the loop count stay.
import test from "node:test"
import assert from "node:assert/strict"
import { stripGif } from "../src/net/gif-strip.js"
import { preparePhoto } from "../src/net/dm-photo.js"

const ascii = s => [...s].map(c => c.charCodeAt(0))
const sub = bytes => { const out = []; for (let i = 0; i < bytes.length; i += 255) { const c = bytes.slice(i, i + 255); out.push(c.length, ...c) } out.push(0); return out }
const app = (id, data) => [0x21, 0xff, 11, ...ascii(id), ...sub(data)]
const comment = text => [0x21, 0xfe, ...sub(ascii(text))]
const gce = delay => [0x21, 0xf9, 4, 0x04, delay & 0xff, delay >> 8, 0, 0]
const frame = (lzw = [0x02, 0x16, 0x8c, 0x2d, 0x99]) => [0x2c, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0x02, ...sub(lzw)]
const plainText = () => [0x21, 0x01, 12, 0, 0, 0, 0, 2, 0, 2, 0, 1, 1, 0, 1, ...sub(ascii("secret caption"))]
const head = [...ascii("GIF89a"), 2, 0, 2, 0, 0x80, 0, 0, 0, 0, 0, 255, 255, 255]

const SECRETS = ["made by Alice's phone", "<x:xmpmeta", "ICCRGBG1", "secret caption", "MGK8BIM0000"]
const dirty = () => new Uint8Array([
  ...head,
  ...app("NETSCAPE2.0", [1, 0, 0]),
  ...comment("made by Alice's phone"),
  ...app("XMP DataXMP", ascii("<x:xmpmeta GPS 51.5,-0.1 />")),
  ...app("ICCRGBG1012", ascii("ICCRGBG1 profile")),
  ...app("MGK8BIM0000", ascii("MGK8BIM0000 photoshop")),
  ...gce(10), ...frame(),
  ...gce(20), ...plainText(),
  ...gce(30), ...frame(),
  0x3b,
  ...ascii("trailing junk after the trailer"),
])
const text = b => String.fromCharCode(...b)
const count = (b, seq) => { let n = 0; for (let i = 0; i + seq.length <= b.length; i++) if (seq.every((x, j) => b[i + j] === x)) n++; return n }

test("every comment, XMP, ICC, Photoshop and text block is gone, and nothing after the trailer", () => {
  const out = stripGif(dirty())
  for (const s of SECRETS) assert.ok(!text(out).includes(s), `${s} left in`)
  assert.ok(!text(out).includes("trailing junk"))
  assert.equal(out.at(-1), 0x3b)
})

test("the frames, their delays and the loop stay, in order", () => {
  const out = stripGif(dirty())
  assert.deepEqual([...out.slice(0, head.length)], head, "header, screen and colour table as they were")
  assert.equal(count(out, [0x2c, 0, 0, 0, 0, 2, 0, 2, 0]), 2, "both frames")
  assert.equal(count(out, [0x21, 0xff, 11, ...ascii("NETSCAPE2.0"), 3, 1, 0, 0, 0]), 1, "the loop forever block")
  // The 20 delay belonged to the dropped text block: it isn't handed to the next frame.
  assert.deepEqual([...out].filter((x, i) => out[i - 1] === 0xf9 && out[i - 2] === 0x21).length, 2)
  assert.equal(text(out).indexOf(text(gce(10))) < text(out).indexOf(text(gce(30))), true)
  assert.equal(count(out, gce(20)), 0)
  assert.deepEqual(stripGif(out), out, "a clean GIF comes out the same")
})

test("a GIF that isn't whole is refused, not sent as it is", () => {
  const d = dirty()
  assert.throws(() => stripGif(d.slice(0, 40)))
  assert.throws(() => stripGif(new Uint8Array(ascii("GIF89a-bytes"))))
  assert.throws(() => stripGif(new Uint8Array(ascii("\xff\xd8\xff\xe1"))))
})

test("preparePhoto sends a GIF with its metadata stripped, never redrawn", async () => {
  let drew = false
  const out = await preparePhoto(new File([dirty()], "cat.gif", { type: "image/gif" }), { draw: async () => { drew = true } })
  assert.equal(drew, false)
  assert.equal(out.type, "image/gif")
  const b = new Uint8Array(await out.arrayBuffer())
  for (const s of SECRETS) assert.ok(!text(b).includes(s), `${s} left in`)
  assert.equal(count(b, [0x2c, 0, 0, 0, 0, 2, 0, 2, 0]), 2)
})

test("preparePhoto refuses a broken GIF in our words", async () => {
  await assert.rejects(preparePhoto(new File(["GIF89a-bytes"], "cat.gif", { type: "image/gif" })), /^Error: Couldn't read that photo\.$/)
})

test("a big GIF is stripped without copying its frames into a JS array (Tron #3)", () => {
  // One frame of 40 MB, as a long GIF's one big frame would be: 255-byte sub-blocks.
  const blocks = 160_000, big = new Uint8Array(head.length + 11 + blocks * 256 + 2)
  big.set(head); let at = head.length
  big.set([0x2c, 0, 0, 0, 0, 2, 0, 2, 0, 0, 0x02], at); at += 11
  for (let k = 0; k < blocks; k++) { big[at] = 255; at += 256 }
  big[at++] = 0; big[at] = 0x3b
  const before = process.resourceUsage().maxRSS * 1024 // peak, so a copy freed again still counts
  const out = stripGif(big.subarray(0, at + 1))
  const grew = process.resourceUsage().maxRSS * 1024 - before
  assert.equal(out.length, at + 1)
  assert.ok(grew < 150 * 1024 * 1024, `peak memory grew ${Math.round(grew / 1048576)} MB`)
})

test("preparePhoto refuses a photo over 50 MB before reading it", async () => {
  const huge = new File([new Uint8Array(51 * 1024 * 1024)], "big.gif", { type: "image/gif" })
  await assert.rejects(preparePhoto(huge), /at most 50 MB/)
})
