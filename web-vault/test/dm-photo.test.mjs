// Photos in DMs: the message the iPhone builds (DMAttachment.content), GIFs kept as they are, everything else
// redrawn as a JPEG no larger than 2400 px (so no EXIF or location goes with it). The drawing is stubbed: node has no
// canvas, and what matters here is what reaches the upload.
import test from "node:test"
import assert from "node:assert/strict"
import { dmContent, fitSize, isGif, preparePhoto, MAX_EDGE } from "../src/net/dm-photo.js"

test("the photo's link goes on its own line after the text, or alone", () => {
  assert.equal(dmContent("  look  ", "https://blossom.example/ab.jpg"), "look\nhttps://blossom.example/ab.jpg")
  assert.equal(dmContent("", "https://blossom.example/ab.jpg"), "https://blossom.example/ab.jpg")
  assert.equal(dmContent(" hi ", null), "hi")
})

test("the long edge comes down to 2400 px, keeping the shape; small photos stay their size", () => {
  assert.deepEqual(fitSize(4800, 3600), { width: MAX_EDGE, height: 1800 })
  assert.deepEqual(fitSize(3000, 6000), { width: 1200, height: MAX_EDGE })
  assert.deepEqual(fitSize(800, 600), { width: 800, height: 600 })
})

test("a GIF is known by its header, never by its type or name", async () => {
  assert.equal(await isGif(new File(["GIF89a..."], "a.gif", { type: "image/gif" })), true)
  assert.equal(await isGif(new File(["GIF87a..."], "paste")), true)
  assert.equal(await isGif(new File(["\xff\xd8\xff\xe1 Exif GPS"], "IMG_0001.gif", { type: "image/gif" })), false, "a renamed JPEG")
})

test("a JPEG named .gif is redrawn, not uploaded with its EXIF", async () => {
  let drew = false
  const out = await preparePhoto(new File(["\xff\xd8 EXIF GPS"], "IMG.gif", { type: "image/gif" }), { draw: async () => { drew = true; return new Blob(["clean"], { type: "image/jpeg" }) } })
  assert.equal(drew, true)
  assert.equal(out.type, "image/jpeg")
  assert.equal(await out.text(), "clean")
})

test("a GIF goes up in its own bytes, without being redrawn", async () => {
  let drew = false
  const out = await preparePhoto(new File(["GIF89a-bytes"], "cat.gif", { type: "image/gif" }), { draw: async () => { drew = true } })
  assert.equal(drew, false)
  assert.equal(out.type, "image/gif")
  assert.equal(await out.text(), "GIF89a-bytes")
})

test("any other photo is replaced by the redrawn JPEG, so its original bytes (and EXIF) never go up", async () => {
  const original = new File(["\xff\xd8 EXIF GPS 51.5,-0.1"], "IMG_0001.HEIC", { type: "image/heic" })
  const out = await preparePhoto(original, { draw: async f => { assert.equal(f, original); return new Blob(["clean-jpeg"], { type: "image/jpeg" }) } })
  assert.equal(out.type, "image/jpeg")
  assert.equal(out.name, "IMG_0001.jpg")
  assert.equal(await out.text(), "clean-jpeg")
})

test("a file that isn't a drawable image says so in our words", async () => {
  await assert.rejects(preparePhoto(new File(["%PDF"], "a.pdf", { type: "application/pdf" })), /Couldn't read that photo/)
  await assert.rejects(preparePhoto(new File(["junk"], "a.png", { type: "image/png" }), { draw: async () => { throw new Error("decode failed: secret detail") } }), /^Error: Couldn't read that photo\.$/)
  await assert.rejects(preparePhoto(null), /Couldn't read that photo/)
})
