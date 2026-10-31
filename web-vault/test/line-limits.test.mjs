// Settings › Feed Text (iPhone AppearanceSettingsView): Compact View 3 and Threaded View 5 lines by default, 1-12,
// kept in this browser; the feed's compact rows and thread cards draw with them.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { lineLimit, setLineLimit, linesText, LINE_LIMITS } from "../src/net/line-limits.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("the iPhone's defaults, its keys, and only whole numbers 1-12 count", () => {
  const s = store()
  assert.equal(lineLimit("compact", s), 3)
  assert.equal(lineLimit("threaded", s), 5)
  assert.deepEqual([LINE_LIMITS.compact.key, LINE_LIMITS.threaded.key], ["display.compactLineLimit", "display.threadedLineLimit"])
  for (const [v, want] of [["1", 1], ["12", 12], ["0", 5], ["13", 5], ["2.5", 5], ["", 5], ["x", 5]]) {
    s.m.set(LINE_LIMITS.threaded.key, v)
    assert.equal(lineLimit("threaded", s), want, v)
  }
  assert.equal(lineLimit("compact", undefined), 3)
})

test("the steppers save inside the range", () => {
  const s = store()
  setLineLimit("compact", 7, s); assert.equal(lineLimit("compact", s), 7)
  setLineLimit("compact", 40, s); assert.equal(lineLimit("compact", s), 12)
  setLineLimit("compact", -3, s); assert.equal(lineLimit("compact", s), 1)
  setLineLimit("compact", NaN, s); assert.equal(lineLimit("compact", s), 1, "not a number: unchanged")
  assert.equal(linesText(1), "1 line")
  assert.equal(linesText(5), "5 lines")
})

test("the feed draws with them and Settings has the Feed Text section", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("components/FeedThreadCard.jsx"), /lines = lineLimit\("threaded"\)/)
  assert.match(src("components/FeedThreadCard.jsx"), /lines=\{depth \? Math\.max\(1, lines - 1\) : lines\}/, "a reply shows one fewer")
  assert.match(src("components/FeedRows.jsx"), /const compactLines = lineLimit\("compact"\)/)
  assert.match(src("components/FeedRows.jsx"), /<CondensedNote key=\{n\.id\} event=\{n\} card lines=\{compactLines\}/)
  assert.match(src("screens/SettingsScreen.jsx"), /<div class="section-label">Feed Text<\/div>\s*<div class="settings-rows"><LineLimitSteppers \/><\/div>/)
})
