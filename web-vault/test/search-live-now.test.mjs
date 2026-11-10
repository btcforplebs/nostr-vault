// Live now at the top of Search (src/screens/SearchLiveNow.jsx): the start page asks with the Your space panel's
// rules and draws the section first. The rules themselves are covered by live-now.test.mjs.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { rowsOf, MAX_ROWS, REFRESH_MS } from "../src/desktop/space/live-now.js"

const src = f => readFileSync(new URL(`../src/screens/${f}`, import.meta.url), "utf8")

test("Search's start page draws Live now before every other section", () => {
  const start = src("SearchStart.jsx")
  const body = start.slice(start.indexOf("return (\n    <>"))
  assert.ok(body.indexOf("<SearchLiveNow") >= 0, "the section is drawn")
  assert.ok(body.indexOf("<SearchLiveNow") < body.indexOf("recent.length > 0"), "and drawn first")
})

test("a live stream alone is enough to leave the Search hint for the start page", () => {
  assert.match(src("SearchStart.jsx"), /if \(!liveStreams\.length && !recent\.length/)
})

test("the section reuses the panel's ask, rows and refresh", () => {
  const live = src("SearchLiveNow.jsx")
  assert.match(live, /from "\.\.\/desktop\/space\/live-now\.js"/)
  assert.match(live, /lookInFront\(look, \{ every: REFRESH_MS \}\)/, "asks again on the panel's period, and not while hidden")
  assert.equal(REFRESH_MS, 2 * 60 * 1000)
  const many = Array.from({ length: MAX_ROWS + 2 }, (_, i) => ({ address: `a${i}` }))
  assert.deepEqual(rowsOf(many).more, 2)
})

test("nothing is drawn when nobody is live, and nothing is published", () => {
  const live = src("SearchLiveNow.jsx")
  assert.match(live, /if \(!rows\.length\) return null/)
  assert.doesNotMatch(live, /\.publish\(|\bsign(Event)?\(/)
})
