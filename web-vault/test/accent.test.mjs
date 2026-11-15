// Settings › Appearance › Accent (src/net/accent.js, components/AccentColorPicker.jsx, public/theme-boot.js): the
// default is today's orange and adds nothing; every colour, ready-made or from the wheel, reads as text in both modes
// and gets a label that reads on its fill; the boot script puts the colour in before the first paint; and the
// orange glows in the CSS follow the accent instead of staying orange.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync } from "node:fs"
import vm from "node:vm"
import { ACCENT_PRESETS, ACCENT_DEFAULT, ACCENT_KEY, ACCENT_CSS_KEY, accent, accentCss, accentTokens, contrast, normalizeHex, setAccent } from "../src/net/accent.js"

const store = (init = {}) => { const m = new Map(Object.entries(init)); return { getItem: k => m.has(k) ? m.get(k) : null, setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) } }
const read = p => readFileSync(new URL(p, import.meta.url), "utf8")
function fakeDoc() {
  const head = { kids: [], appendChild(el) { this.kids.push(el); el.parent = this } }
  return { head, getElementById: id => head.kids.find(k => k.id === id) ?? null, createElement: () => ({ id: "", textContent: "", remove() { head.kids.splice(head.kids.indexOf(this), 1) } }) }
}
function readable(hex) {
  const t = accentTokens(hex)
  assert.ok(contrast(t.dark["--accent"], "#1c1c1e") >= 4.5, `${hex} dark text ${t.dark["--accent"]}`)
  assert.ok(contrast(t.light["--accent"], "#ffffff") >= 4.5, `${hex} light text ${t.light["--accent"]}`)
  assert.ok(contrast(t.dark["--on-accent"], t.dark["--accent"]) >= 3, `${hex} dark label`)
  assert.ok(contrast(t.light["--on-accent"], t.light["--accent"]) >= 3, `${hex} light label`)
  assert.ok(contrast(t.light["--on-accent"], t.light["--accent-light"]) >= 3, `${hex} light label on the gradient's light end`)
}

test("the default is today's orange: no sheet, so the app looks exactly as before", () => {
  assert.equal(accent(store()), ACCENT_DEFAULT)
  assert.equal(accentCss(ACCENT_DEFAULT), "")
  assert.equal(accentCss("E67326"), "")
  assert.equal(ACCENT_PRESETS[0].hex, ACCENT_DEFAULT)
  assert.equal(ACCENT_PRESETS.length, 8)
})

test("every ready-made colour reads as text in dark and in light, with a readable label on its fill", () => {
  for (const p of ACCENT_PRESETS) readable(p.hex)
})

test("any colour from the wheel reads too: 300 random colours, from neon yellow to navy", () => {
  let seed = 7
  const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647
  for (const hex of ["#ffff00", "#00ffff", "#ffffff", "#000000", "#000080", "#39ff14", "#ff00ff"]) readable(hex)
  for (let i = 0; i < 300; i++) readable("#" + Math.floor(rnd() * 0xffffff).toString(16).padStart(6, "0"))
})

test("a pale colour keeps its own shade for fills and glows in light mode", () => {
  const t = accentTokens("#ffd60a")
  assert.notEqual(t.light["--accent"], "#ffd60a") // deepened for text on white
  assert.equal(t.light["--accent-rgb"], "255 214 10")
  assert.equal(t.dark["--accent"], "#ffd60a") // as picked in dark: it already reads on a card
  assert.equal(t.dark["--on-accent"], "#000") // white on yellow doesn't read
})

test("hex input: short, long, with or without #, anything else refused", () => {
  assert.equal(normalizeHex("#ABC"), "#aabbcc")
  assert.equal(normalizeHex("0a84ff"), "#0a84ff")
  assert.equal(normalizeHex("red"), null)
  assert.equal(accent(store({ [ACCENT_KEY]: "nonsense" })), ACCENT_DEFAULT)
})

test("picking saves the colour and its sheet; going back to orange removes both", () => {
  const s = store(), doc = fakeDoc()
  setAccent("#0a84ff", s, doc)
  assert.equal(s.getItem(ACCENT_KEY), "#0a84ff")
  assert.match(s.getItem(ACCENT_CSS_KEY), /html:root, html \[data-theme="dark"\] \{ --accent: #0a84ff;/)
  assert.match(s.getItem(ACCENT_CSS_KEY), /html:root\[data-theme="light"\], html \[data-theme="light"\] \{/)
  assert.equal(doc.getElementById("nv-accent").textContent, s.getItem(ACCENT_CSS_KEY))
  setAccent(ACCENT_DEFAULT, s, doc)
  assert.equal(s.getItem(ACCENT_CSS_KEY), null)
  assert.equal(doc.getElementById("nv-accent"), null)
})

test("the boot script puts the saved colour in before the first paint", () => {
  const document = { documentElement: { dataset: {} }, head: { kids: [], appendChild(el) { this.kids.push(el) } }, createElement: () => ({}) }
  const css = accentCss("#bf5af2")
  vm.runInNewContext(read("../public/theme-boot.js"), { document, localStorage: store({ [ACCENT_CSS_KEY]: css }), matchMedia: () => ({ matches: false }) })
  assert.equal(document.head.kids.length, 1)
  assert.equal(document.head.kids[0].id, "nv-accent")
  assert.equal(document.head.kids[0].textContent, css)
})

test("the CSS glows follow the accent: no hard-coded orange left in the stylesheets", () => {
  const dirs = ["../src/styles/", "../src/readers/", "../src/box/", "../src/napplet/"]
  const left = []
  for (const d of dirs) for (const f of readdirSync(new URL(d, import.meta.url)).filter(f => f.endsWith(".css"))) {
    const css = read(d + f)
    if (/rgba?\(\s*230[ ,]+115[ ,]+38/.test(css) && !/tokens\.css$/.test(f)) left.push(f)
  }
  assert.deepEqual(left, [])
  assert.match(read("../src/styles/tokens.css"), /--accent-rgb: 230 115 38;/)
})

test("Appearance shows the accent row under Mode", () => {
  const page = read("../src/screens/settings/AppearancePage.jsx")
  assert.ok(page.indexOf("AppearanceModePicker />") < page.indexOf("AccentColorPicker />"))
})

test("Light's paper mixes 5% of the accent into the warm off-white", async () => {
  const { paper } = await import("../src/net/accent.js")
  assert.equal(paper("#e67326"), "#f5ebe1")
  assert.equal(paper("#0a84ff"), "#eaecec")
  assert.equal(paper("not a colour"), "#f5ebe1")
})
