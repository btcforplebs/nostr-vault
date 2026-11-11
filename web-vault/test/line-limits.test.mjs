// Settings › Feed Text (iPhone AppearanceSettingsView): Threaded View 5 lines by default, 1-12, kept in this browser;
// thread cards draw with it. Compact View and its line count are gone (2026-11-11).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { lineLimit, setLineLimit, linesText, LINE_LIMITS } from "../src/net/line-limits.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("the iPhone's defaults, its keys, and only whole numbers 1-12 count", () => {
  const s = store()
  assert.equal(lineLimit("threaded", s), 5)
  assert.deepEqual(Object.keys(LINE_LIMITS), ["threaded"], "no Compact View line count")
  assert.equal(LINE_LIMITS.threaded.key, "display.threadedLineLimit")
  for (const [v, want] of [["1", 1], ["12", 12], ["0", 5], ["13", 5], ["2.5", 5], ["", 5], ["x", 5]]) {
    s.m.set(LINE_LIMITS.threaded.key, v)
    assert.equal(lineLimit("threaded", s), want, v)
  }
  assert.equal(lineLimit("threaded", undefined), 5)
})

test("the steppers save inside the range", () => {
  const s = store()
  setLineLimit("threaded", 7, s); assert.equal(lineLimit("threaded", s), 7)
  setLineLimit("threaded", 40, s); assert.equal(lineLimit("threaded", s), 12)
  setLineLimit("threaded", -3, s); assert.equal(lineLimit("threaded", s), 1)
  setLineLimit("threaded", NaN, s); assert.equal(lineLimit("threaded", s), 1, "not a number: unchanged")
  assert.equal(linesText(1), "1 line")
  assert.equal(linesText(5), "5 lines")
})

test("the feed draws with them and Settings has the Feed Text section", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("components/FeedThreadCard.jsx"), /lines = lineLimit\("threaded"\)/)
  assert.match(src("components/FeedThreadCard.jsx"), /lines=\{depth \? Math\.max\(1, lines - 1\) : lines\}/, "a reply shows one fewer")
  assert.doesNotMatch(src("components/FeedRows.jsx"), /layout === "condensed"/, "Compact View is gone (2026-11-11)")
  assert.match(src("screens/settings/AppearancePage.jsx"), /<Section label="Feed Text"><LineLimitSteppers \/><\/Section>/, "Settings › Appearance, as the iPhone")
})
