// Settings › Reactions › Default Reaction (HavenConfig.defaultReactionEmoji): ❤️ by default, one emoji only.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { defaultReaction, setDefaultReaction, DEFAULT_REACTION } from "../src/net/reaction-pref.js"

const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }

test("❤️ by default; a picked emoji is kept; anything that isn't one emoji is ignored", () => {
  const s = store()
  assert.equal(defaultReaction(s), DEFAULT_REACTION)
  setDefaultReaction("🔥", s); assert.equal(defaultReaction(s), "🔥")
  setDefaultReaction("👍🏽", s); assert.equal(defaultReaction(s), "👍🏽", "a skin tone is one emoji")
  setDefaultReaction("🇺🇸", s); assert.equal(defaultReaction(s), "🇺🇸")
  for (const bad of ["", "abc", "🔥🔥", "+", null]) { setDefaultReaction(bad, s); assert.equal(defaultReaction(s), "🇺🇸", String(bad)) }
  s.m.set("display.defaultReactionEmoji", "nope")
  assert.equal(defaultReaction(s), DEFAULT_REACTION, "a bad stored value reads as the default")
  setDefaultReaction("❤️", s)
  assert.equal(s.m.has("display.defaultReactionEmoji"), false, "back to the default: nothing kept")
  assert.equal(defaultReaction(undefined), DEFAULT_REACTION)
})

test("Settings has the Reactions row", () => {
  const src = readFileSync(new URL("../src/screens/SettingsScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /<div class="section-label">Reactions<\/div>\s*<div class="settings-rows"><DefaultReactionRow \/><\/div>/)
})
