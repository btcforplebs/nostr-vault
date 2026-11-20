// small-image.js (perf audit 2026-11-20 L2, L3): avatars and feed photos are drawn at the size shown, never larger.
import test from "node:test"
import assert from "node:assert/strict"
import { scaleFor, stillOf } from "../src/components/small-image.js"

test("cover fills the slot, contain fits inside it, and nothing is ever enlarged", () => {
  assert.equal(scaleFor(4000, 3000, { w: 80, h: 80 }, "cover"), 80 / 3000)
  assert.equal(scaleFor(4000, 3000, { w: 80, h: 80 }, "contain"), 80 / 4000)
  assert.equal(scaleFor(1200, 3600, { w: 1200, h: 800 }, "contain"), 800 / 3600, "a tall photo stops at the slot's height")
  assert.equal(scaleFor(64, 64, { w: 80, h: 80 }, "cover"), 1)
})

test("where it can't be drawn small (no createImageBitmap) the original is drawn, and nothing is fetched", async () => {
  const was = globalThis.fetch
  let asked = 0
  globalThis.fetch = async () => { asked++; throw new Error("fetched") }
  try {
    assert.deepEqual(await stillOf("https://media.example/a.gif", { w: 40, h: 40 }, "cover"), { src: null, animated: false })
    assert.equal(asked, 0)
  } finally { globalThis.fetch = was }
})
