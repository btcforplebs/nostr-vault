// Settings › Media › Autoplay Videos (iPhone MediaSettingsView): on by default, kept in this browser, and the feed's
// inline video doesn't start itself when it is off.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { autoplayOn, setAutoplay } from "../src/net/media-prefs.js"

const store = () => { const m = new Map(); return { getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("autoplay is on by default, as HavenConfig.autoplayVideos, and the switch keeps its choice", () => {
  const s = store()
  assert.equal(autoplayOn(s), true)
  setAutoplay(false, s)
  assert.equal(autoplayOn(s), false)
  setAutoplay(true, s)
  assert.equal(autoplayOn(s), true)
  assert.equal(autoplayOn(undefined), true, "no storage: the default")
  assert.equal(autoplayOn({ getItem: () => { throw new Error("blocked") } }), true)
})

test("the inline video checks the switch before it plays itself; Settings has the switch under Media", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("components/MediaParts.jsx"), /if \(!v \|\| reducedMotion\(\) \|\| !autoplayOn\(\) \|\| !globalThis\.IntersectionObserver\) return/)
  assert.match(src("screens/SettingsScreen.jsx"), /<div class="section-label">Media<\/div>\s*<div class="settings-rows"><AutoplaySwitch \/><\/div>/)
  assert.match(src("components/AutoplaySwitch.jsx"), /Autoplay Videos/)
})
