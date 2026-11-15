// Plan step 1 (OUTBOX/NV_WEB_ONE_PLAN.md): napplets draw with the shell's theme, from the first paint and live after.
// The pure parts: the token list matches styles/tokens.css, the first-paint block can't be broken out of, the theme
// code goes into every napplet of ours that takes the theme, and the napplet side applies tokens, the mode, the dark
// island and NIP-5D's three colours. The live broadcast and no-flash first paint are checked in a browser
// (docs/napplets/STEP1_THEME.md).
import test from "node:test"
import assert from "node:assert/strict"
import fs from "node:fs"
import { THEME_TOKENS, cleanTokens, themeHead, onThemeChange, THEME_STORAGE_KEYS } from "../src/napplet/theme.js"
import { injectTheme, THEME_MARKER } from "../src/napplet/theme-inject.js"
import { asScript } from "../src/napplet/wot-inject.js"
import { FIRST_PARTY_LIST } from "../src/napplet/first-party-list.js"
import { artifactOf } from "../tools/napplet-release.mjs"
import { buildSrcdoc } from "../src/napplet/srcdoc.js"

const read = p => fs.readFileSync(new URL(`../${p}`, import.meta.url), "utf8")

test("the token list is every token of styles/tokens.css", () => {
  const css = read("src/styles/tokens.css")
  const block = css.slice(css.indexOf(':root, [data-theme="dark"]'), css.indexOf("\n}", css.indexOf(':root, [data-theme="dark"]')))
  const names = [...block.matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)].map(m => m[1])
  assert.deepEqual([...THEME_TOKENS].sort(), [...new Set(names)].sort())
  // light.css only re-colours tokens.css's names: nothing there that a napplet wouldn't get.
  for (const m of read("src/styles/light.css").matchAll(/^\s*(--[a-z0-9-]+)\s*:/gm)) assert.ok(THEME_TOKENS.includes(m[1]), m[1])
})

test("token values that could end the style rule or block are dropped", () => {
  assert.deepEqual(cleanTokens({ "--bg": "#fff", "--x": "red; } body { display: none", "--y": "</style><script>", "bad name": "#000", "--z": "" }), { "--bg": "#fff" })
  assert.deepEqual(cleanTokens(null), {})
})

test("the first-paint block sets the mode and the tokens, ranked over the napplet's own :root", () => {
  const head = themeHead({ nv: { mode: "light", tokens: { "--bg": "#f6f1eb", "--accent": "#c2571a", "--x": "a}b" } } })
  assert.equal(head, `<style id="nv-theme">:root:root { color-scheme: light; --bg: #f6f1eb; --accent: #c2571a; }</style>`)
  assert.equal(themeHead({ colors: { background: "#000" } }), "") // no nv block: nothing to add
  // After the bootstrap, before the napplet's own head: no napplet style or script runs first.
  const doc = buildSrcdoc(`<html><head><style>:root{--bg:#000}</style></head></html>`, "boot()", "default-src 'none'", head)
  assert.ok(doc.indexOf("boot()") < doc.indexOf('id="nv-theme"') && doc.indexOf('id="nv-theme"') < doc.indexOf(":root{--bg:#000}"))
})

test("our napplets that take the theme carry the theme code once, and none keeps the old three-colour copy", () => {
  for (const n of FIRST_PARTY_LIST) {
    const src = read(`napplets/${n.file}/index.html`)
    assert.equal(src.split(THEME_MARKER).length, n.domains.includes("theme") ? 2 : 1, n.file)
    assert.doesNotMatch(src, /setProperty\("--bg", c\.background\)/, n.file)
    const art = artifactOf(n)
    assert.ok(!art.includes(THEME_MARKER), n.file)
    if (n.domains.includes("theme")) assert.match(art, /function nvTheme\(n, opts\)[\s\S]*\bnvTheme\(n\b/, n.file)
  }
  assert.throws(() => injectTheme(`${THEME_MARKER}${THEME_MARKER}`, "x"), /at most one/)
  assert.equal(injectTheme("<p>no marker</p>", "x"), "<p>no marker</p>")
})

// The napplet side (theme-client.js) in a stand-in document.
function napplet(theme) {
  const props = new Map(), events = [], root = { style: { setProperty: (k, v) => props.set(k, v), colorScheme: "" }, dataset: {} }
  const g = { document: { documentElement: root }, dispatchEvent: e => events.push(e.detail), CustomEvent: class { constructor(t, o) { this.detail = o.detail } } }
  let changed
  const n = { theme: { get: async () => theme, onChanged: fn => { changed = fn } } }
  const run = new Function("document", "dispatchEvent", "CustomEvent", "n", "opts", `${asScript(read("src/napplet/theme-client.js"))}\nnvTheme(n, opts)`)
  return { props, root, events, change: t => changed(t), start: opts => run(g.document, g.dispatchEvent, g.CustomEvent, n, opts) }
}
const tick = () => new Promise(r => setTimeout(r, 0))

test("napplet side: tokens and mode on first answer, again on theme.changed", async () => {
  const theme = { colors: {}, nv: { mode: "light", tokens: { "--bg": "#f6f1eb", "--accent": "#c2571a", "--x": "a;b" }, dark: { "--bg": "#000" } } }
  const s = napplet(theme)
  s.start()
  await tick()
  assert.equal(s.props.get("--bg"), "#f6f1eb")
  assert.equal(s.props.has("--x"), false)
  assert.equal(s.root.dataset.theme, "light")
  assert.equal(s.root.style.colorScheme, "light")
  s.change({ nv: { mode: "dark", tokens: { "--bg": "#000", "--accent": "#ff2d55" } } })
  assert.equal(s.props.get("--accent"), "#ff2d55")
  assert.equal(s.root.dataset.theme, "dark")
  assert.deepEqual(s.events.map(e => e.mode), ["light", "dark"])
})

test("napplet side: a dark island takes the dark set in Light; an older shell's three colours still apply", async () => {
  const s = napplet({ nv: { mode: "light", tokens: { "--bg": "#f6f1eb" }, dark: { "--bg": "#000", "--accent": "#e67326" } } })
  s.start({ island: "dark" })
  await tick()
  assert.equal(s.props.get("--bg"), "#000")
  assert.equal(s.root.dataset.theme, "dark")
  const o = napplet({ colors: { background: "#111", text: "#eee", primary: "#0af" } })
  o.start()
  await tick()
  assert.deepEqual([...o.props], [["--bg", "#111"], ["--text", "#eee"], ["--accent", "#0af"]])
})

test("the shell side fires once per burst, for Mode, accent, the device, and another tab", async () => {
  const L = { app: new Set(), acc: new Set(), mq: new Set(), win: new Set() }
  const win = {
    requestAnimationFrame: f => setTimeout(f, 0),
    matchMedia: () => ({ addEventListener: (e, f) => L.mq.add(f), removeEventListener: (e, f) => L.mq.delete(f) }),
    addEventListener: (e, f) => L.win.add(f), removeEventListener: (e, f) => L.win.delete(f),
  }
  let n = 0
  const off = onThemeChange(() => n++, { win, onAppearance: f => (L.app.add(f), () => L.app.delete(f)), onAccent: f => (L.acc.add(f), () => L.acc.delete(f)) })
  for (const f of [...L.app, ...L.acc, ...L.mq]) f()
  await new Promise(r => setTimeout(r, 5))
  assert.equal(n, 1)
  for (const f of L.win) f({ key: "nv-session" })
  await new Promise(r => setTimeout(r, 5))
  assert.equal(n, 1)
  for (const k of THEME_STORAGE_KEYS) for (const f of L.win) f({ key: k })
  await new Promise(r => setTimeout(r, 5))
  assert.equal(n, 2)
  off()
  assert.equal(L.app.size + L.acc.size + L.mq.size + L.win.size, 0)
})
