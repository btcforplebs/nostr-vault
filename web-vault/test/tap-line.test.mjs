// The tap line (src/components/tap-line.js), as the iPhone's TapLandingLine: a tapped post's top lands 20 px under the
// top bar's buttons, in the Feed and on the thread screen, whatever its height; and the room under a list that lets
// the last posts reach it is the phone's only (styles/feeds.css).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { TAP_GAP, landingScroll, tapLine } from "../src/components/tap-line.js"
import { feedPostOpen } from "../src/components/feed-tap.js"

const rect = (top, bottom) => ({ top, bottom, height: bottom - top })
const bar = (top, buttons, stick = "0px") => ({
  getBoundingClientRect: () => rect(top, top + 62),
  querySelectorAll: () => buttons.map(([t, b]) => ({ getBoundingClientRect: () => rect(t, b) })),
  stick,
})
globalThis.getComputedStyle = el => ({ top: el.stick })

test("the line is 20 px under the lowest button, the iPhone's gap", () => {
  assert.equal(TAP_GAP, 20)
  assert.equal(tapLine(bar(0, [[9, 53], [9, 53]])), 73) // the Feed's pills
  assert.equal(tapLine(bar(0, [[10, 55], [13, 51]])), 75) // the thread's Done and reply capsule
})

test("the line is where the bar sticks, not where it sits before it has reached the top", () => {
  assert.equal(tapLine(bar(12, [[21, 65]])), 73)
  assert.equal(tapLine(bar(0, [[9, 53]], "8px")), 81)
})

test("hidden buttons don't count; no bar is the gap from the top", () => {
  assert.equal(tapLine(bar(0, [[9, 53], [0, 0]])), 73)
  assert.equal(tapLine(null), TAP_GAP)
})

test("a post lands on the line whatever its height: only its top counts", () => {
  assert.equal(landingScroll(1200, 400, 73), 1527) // tapped mid-screen: the list moves up
  assert.equal(landingScroll(1200, 40, 73), 1167) // under the bar: down
  assert.equal(landingScroll(1200, 73, 73), 1200) // on it: no move
  assert.equal(landingScroll(10, 30, 73), 0) // never above the page top
})

test("no post is open in the Feed before a tap", () => {
  assert.equal(feedPostOpen(), false)
})

test("room under the list on the phone only", () => {
  const css = readFileSync(new URL("../src/styles/feeds.css", import.meta.url), "utf8")
  assert.match(css, /\.tap-room \{ height: calc\(100dvh - 75px\); \}/)
  assert.match(css, /\.desk-app \.tap-room \{ display: none; \}/)
})
