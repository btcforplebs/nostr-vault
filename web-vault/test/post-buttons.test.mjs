// Settings › Post buttons (iPhone PostButtons): the zap button on posts is off until turned on, stored under the
// iPhone's key and value; NoteCard draws it only then. Profile zaps don't depend on it.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { showsZap, zapButtonOn, setZapButton } from "../src/net/post-buttons.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)) } }

test("off by default; the switch writes the iPhone's ⚡️ under postButtons; a bare ⚡ counts", () => {
  const s = store()
  assert.equal(zapButtonOn(s), false)
  setZapButton(true, s)
  assert.equal(s.m.get("postButtons"), "⚡️")
  assert.equal(zapButtonOn(s), true)
  setZapButton(false, s)
  assert.equal(zapButtonOn(s), false)
  assert.equal(showsZap("⚡"), true)
  assert.equal(showsZap("🔥"), false)
  assert.equal(zapButtonOn(undefined), false)
})

test("NoteCard draws the zap button only when it is on; the profile zap stays; Settings has the switch", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.match(src("components/NoteCard.jsx"), /\{zapButtonOn\(\) && <ZapButton note=\{note\} \/>\}/)
  assert.doesNotMatch(src("screens/PersonScreen.jsx"), /zapButtonOn/)
  assert.match(src("screens/SettingsScreen.jsx"), /<div class="section-label">Post buttons<\/div>\s*<div class="settings-rows"><PostButtonsSwitch \/><\/div>/)
})
