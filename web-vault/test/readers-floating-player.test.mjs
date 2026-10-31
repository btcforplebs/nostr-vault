// The app-wide player bar (FloatingButtonRow): mounted once by the app, drawn while something plays, hidden while a
// screen (Music, Live) shows its own bar. Checked in headless Chrome too: floating left of Post above the tab bar,
// gone while a hosted bar is up.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const read = p => readFileSync(new URL(p, import.meta.url), "utf8")

test("the app mounts the floating player once, after the tab bar", () => {
  const main = read("../main.jsx")
  assert.equal(main.match(/<FloatingPlayer \/>/g)?.length, 1)
  assert.match(main, /<TabBar [^\n]*\/>\}\n\s*<FloatingPlayer \/>/)
})

test("the floating bar hides while a screen's own bar is up, and screens count themselves in and out", () => {
  const bar = read("../src/readers/PlayerBar.jsx")
  assert.match(bar, /if \(!t \|\| \(floating && others > 0\)\) return null/)
  assert.match(bar, /hosted\+\+; hostChanged\(\)\n\s*return \(\) => \{ hosted--; hostChanged\(\) \}/)
  assert.match(read("../src/readers/MusicScreen.jsx"), /<PlayerBar onOpen=\{open\} \/>/)
  assert.match(read("../src/readers/LiveScreen.jsx"), /<PlayerBar onOpenLive=/)
  assert.match(read("../src/readers/FloatingPlayer.jsx"), /<PlayerBar floating \/>/)
})
