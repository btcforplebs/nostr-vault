// The web live player's PiP button (PiP plan lane D): only where the browser can do PiP, and a second tap brings the
// video back. Fake video and document; the real API is the browser's.
import test from "node:test"
import assert from "node:assert/strict"
import { canPiP, togglePiP } from "../src/components/pip.js"

const video = (extra = {}) => ({ requestPictureInPicture: async () => "in", disablePictureInPicture: false, ...extra })

test("PiP only where the browser has it on, and the video allows it", () => {
  assert.equal(canPiP(video(), { pictureInPictureEnabled: true }), true)
  assert.equal(canPiP(video(), { pictureInPictureEnabled: false }), false, "turned off (policy, or the user)")
  assert.equal(canPiP(video(), {}), false, "no API: Firefox")
  assert.equal(canPiP({}, { pictureInPictureEnabled: true }), false, "no requestPictureInPicture on the element")
  assert.equal(canPiP(video({ disablePictureInPicture: true }), { pictureInPictureEnabled: true }), false)
  assert.equal(canPiP(null, { pictureInPictureEnabled: true }), false)
})

test("a tap goes in; a tap on the video in PiP comes back out", async () => {
  const v = video()
  let exited = 0
  const doc = { pictureInPictureElement: null, exitPictureInPicture: async () => { exited++ } }
  assert.equal(await togglePiP(v, doc), "in")
  doc.pictureInPictureElement = v
  await togglePiP(v, doc)
  assert.equal(exited, 1)
})
