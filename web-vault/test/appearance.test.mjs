// Settings › Appearance › Mode (src/net/appearance.js, styles/light.css, public/theme-boot.js): Dark by default,
// Light or Auto; the page carries <html data-theme="light">; the boot script reads the same key before paint; the
// light set only overrides tokens the dark set defines; the trust globe stays dark.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { appearance, setAppearance, resolveAppearance, paintAppearance, APPEARANCE_KEY } from "../src/net/appearance.js"

const store = (init = {}) => { const m = new Map(Object.entries(init)); return { getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)) } }
const win = light => ({ matchMedia: q => ({ matches: q.includes("light") && light }) })
function fakeDoc() {
  const meta = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v } }
  return { documentElement: { dataset: {} }, querySelector: s => (s.includes("theme-color") ? meta : null), meta }
}
const read = p => readFileSync(new URL(p, import.meta.url), "utf8")
const tokenNames = css => new Set([...css.matchAll(/(--[a-z0-9-]+)\s*:/g)].map(m => m[1]))

test("dark is the default, and anything unknown reads as dark", () => {
  assert.equal(appearance(store()), "dark")
  assert.equal(appearance(store({ [APPEARANCE_KEY]: "neon" })), "dark")
  assert.equal(appearance(store({ [APPEARANCE_KEY]: "light" })), "light")
})

test("auto follows the device; dark and light ignore it", () => {
  assert.equal(resolveAppearance("auto", win(true)), "light")
  assert.equal(resolveAppearance("auto", win(false)), "dark")
  assert.equal(resolveAppearance("dark", win(true)), "dark")
  assert.equal(resolveAppearance("light", win(false)), "light")
})

test("painting light sets data-theme and the bar colour; dark removes it", () => {
  const doc = fakeDoc()
  paintAppearance("light", doc)
  assert.equal(doc.documentElement.dataset.theme, "light")
  // Warm paper with 5% of the (default orange) accent.
  assert.equal(doc.meta.attrs.content, "#f5ebe1")
  paintAppearance("dark", doc)
  assert.equal(doc.documentElement.dataset.theme, undefined)
  assert.equal(doc.meta.attrs.content, "#000000")
})

test("setting a mode saves it and paints it at once", () => {
  const s = store(), doc = fakeDoc()
  setAppearance("light", s, { ...win(false), document: doc })
  assert.equal(s.getItem(APPEARANCE_KEY), "light")
  assert.equal(doc.documentElement.dataset.theme, "light")
})

test("the boot script reads the same key, so the first paint is already the right mode", () => {
  const src = read("../public/theme-boot.js")
  for (const [saved, device, want] of [["light", false, "light"], ["auto", true, "light"], ["auto", false, undefined], ["dark", true, undefined], [null, true, undefined]]) {
    const document = { documentElement: { dataset: {} } }
    vm.runInNewContext(src, { document, localStorage: store(saved ? { [APPEARANCE_KEY]: saved } : {}), matchMedia: win(device).matchMedia })
    assert.equal(document.documentElement.dataset.theme, want, `${saved} / device light ${device}`)
  }
  assert.match(read("../index.html"), /<head>[\s\S]*<script src="\.\/theme-boot\.js"><\/script>[\s\S]*<\/head>/)
})

test("light mode only overrides tokens dark mode defines, and covers the page colours", () => {
  const dark = tokenNames(read("../src/styles/tokens.css")), light = tokenNames(read("../src/styles/light.css"))
  for (const t of light) assert.ok(dark.has(t), `${t} is light-only`)
  for (const t of ["--bg", "--s1", "--s2", "--s3", "--text", "--text-2", "--text-3", "--ink", "--hair", "--strong", "--accent", "--menu", "--glass", "--action"]) assert.ok(light.has(t), `light mode leaves ${t} dark`)
})

test("the trust globe screen stays dark in light mode", () => {
  assert.match(read("../src/screens/WotScreen.jsx"), /<main class="screen wot" data-theme="dark">/)
  assert.match(read("../src/styles/tokens.css"), /:root, \[data-theme="dark"\] \{/)
})
