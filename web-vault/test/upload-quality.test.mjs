// Settings › Media & Cache › Upload Quality (net/upload-quality.js, plan W2): Standard by default, Original sends photos
// in notes, live chat and DMs as they are, location still removed. One setting, no per-upload switch.
import test from "node:test"
import assert from "node:assert/strict"
import { ORIGINAL, STANDARD, UPLOAD_QUALITY_CHOICES, setUploadQuality, uploadQuality, uploadQualityNote } from "../src/net/upload-quality.js"
import { preparePhoto } from "../src/net/dm-photo.js"
import { hasLocation } from "../src/net/media-privacy.js"
import { settingsAnswer, settingsHandlers } from "../src/napplet/settings-answer.js"

const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("Standard unless Original was picked; anything else saved reads as Standard", () => {
  const s = store()
  assert.equal(uploadQuality(s), STANDARD)
  setUploadQuality(ORIGINAL, s); assert.equal(uploadQuality(s), ORIGINAL)
  setUploadQuality("huge", s); assert.equal(uploadQuality(s), STANDARD)
  s.setItem("media.uploadQuality", "weird"); assert.equal(uploadQuality(s), STANDARD)
  assert.equal(uploadQuality({ getItem() { throw new Error("blocked") } }), STANDARD)
  assert.equal(uploadQuality(undefined), STANDARD, "node / no storage")
  assert.deepEqual(UPLOAD_QUALITY_CHOICES.map(c => c.label), ["Standard", "Original"])
  assert.match(uploadQualityNote(STANDARD), /2048 px/)
})

// A JPEG with an EXIF GPS IFD (one GPSLatitudeRef entry), the smallest one media-privacy reads as located.
function locatedJpeg() {
  const tiff = [0x4d, 0x4d, 0, 42, 0, 0, 0, 8, 0, 1, 0x88, 0x25, 0, 4, 0, 0, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0,
    0, 1, 0, 1, 0, 2, 0, 0, 0, 2, 0x4e, 0, 0, 0, 0, 0, 0, 0]
  const app1 = [..."Exif\0\0"].map(c => c.charCodeAt(0)).concat(tiff)
  const len = app1.length + 2
  return new Uint8Array([0xff, 0xd8, 0xff, 0xe1, len >> 8, len & 255, ...app1, 0xff, 0xd9])
}

test("a DM photo on Original is sent at full size, not redrawn, with its location taken out", async () => {
  const raw = locatedJpeg()
  assert.equal(hasLocation(raw), true, "the fixture does carry a location")
  const never = async () => { throw new Error("should not redraw") }
  const out = await preparePhoto(new File([raw], "IMG.JPG", { type: "image/jpeg" }), { draw: never, quality: ORIGINAL })
  assert.equal(out.type, "image/jpeg"); assert.equal(out.name, "IMG.JPG")
  const sent = new Uint8Array(await out.arrayBuffer())
  assert.equal(sent.length, raw.length, "same bytes, location zeroed in place")
  assert.equal(hasLocation(sent), false)
  await assert.rejects(preparePhoto(new File(["%PDF"], "a.jpg", { type: "image/jpeg" }), { draw: never, quality: ORIGINAL }), /Couldn't read that photo/)
})

test("a DM photo on Standard is still redrawn", async () => {
  let drew = false
  await preparePhoto(new File([locatedJpeg()], "IMG.JPG", { type: "image/jpeg" }), { draw: async () => { drew = true; return new Blob(["j"]) }, quality: STANDARD })
  assert.equal(drew, true)
})

test("the Settings napplet's Media page shows the choice and sets only a known one", () => {
  const w = { autoplayNote: () => "", cacheNote: "" }
  const d = settingsAnswer("media", { autoplay: true, uploadQuality: ORIGINAL }, w)
  assert.equal(d.uploadQuality.value, ORIGINAL)
  assert.deepEqual(d.uploadQuality.choices.map(c => c.value), [STANDARD, ORIGINAL])
  assert.match(d.uploadQuality.note, /as they are/)
  const sets = []
  const pipe = { answer: () => d, keyPage: () => false, box: () => false, ctl: { set: (k, v) => sets.push([k, v]) } }
  const set = settingsHandlers(pipe).find(h => h.actions.includes("set"))
  const run = p => set.deliver(p)
  assert.equal(run({ key: "uploadQuality", value: STANDARD }).ok, true)
  assert.equal(run({ key: "uploadQuality", value: "huge" }).ok, false)
  assert.deepEqual(sets, [["uploadQuality", STANDARD]])
})
