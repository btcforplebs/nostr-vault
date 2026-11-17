// The tab and home-screen icon follow the accent (src/net/accent-icon.js): the art's own shades for every preset,
// only the accent parts of the icon change, the default orange leaves the file icons alone, and the boot script sets
// the saved icon before the app loads.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { ACCENT_PRESETS } from "../src/net/accent.js"
import { ICON_KEY, applyIcon, iconShades, paintIcon, svgDataUrl, tintIconSvg } from "../src/net/accent-icon.js"

const read = p => readFileSync(new URL(p, import.meta.url), "utf8")
const svg = read("../public/icon.svg")

// RESEARCH/NV_ACCENT_ICONS/README.md, "Shades per preset" (what the art was made with).
const README_HI = { "#e67326": "#fa9447", "#ffb800": "#ffc735", "#3ddc84": "#5cf29f", "#00c2b8": "#00f7ea", "#2e7dff": "#639eff", "#662482": "#8d1fbc", "#ff2d87": "#ff62a5", "#a8071a": "#e4001b" }

test("every preset gets the same hi shade as the icon art", () => {
  for (const { hex } of ACCENT_PRESETS) assert.equal(iconShades(hex).hi, README_HI[hex], hex)
})

test("only the glow and the outlines change; the default is the file as it is", () => {
  assert.equal(tintIconSvg(svg, "#e67326"), svg)
  const blue = tintIconSvg(svg, "#2E7DFF")
  assert.doesNotMatch(blue, /#e67326|#fa9447/i)
  assert.equal(blue.split("#2e7dff").length - 1, (svg.match(/#e67326/gi) ?? []).length)
  assert.equal(blue.split("#639eff").length - 1, (svg.match(/#fa9447/gi) ?? []).length)
  assert.equal(blue.replace(/#2e7dff/g, "#E67326").replace(/#639eff/g, "#FA9447"), svg)
})

function fakeDoc() {
  const links = { icon: { href: "./icon.svg" }, "apple-touch-icon": { href: "./icon-180.png" } }
  for (const l of Object.values(links)) { l.setAttribute = (_, v) => { l.href = v }; l.getAttribute = () => l.href }
  return { links, baseURI: "https://nostrvault.app/web/", querySelector: q => links[/rel="([^"]+)"/.exec(q)[1]] }
}
const store = () => { const m = new Map(); return { m, getItem: k => m.get(k) ?? null, setItem: (k, v) => m.set(k, v), removeItem: k => m.delete(k) } }

test("a colour sets the tinted tab icon and saves it; orange puts the files back", async () => {
  const doc = fakeDoc(), s = store()
  const realFetch = globalThis.fetch
  globalThis.fetch = async url => { assert.equal(String(url), "https://nostrvault.app/web/icon.svg"); return { ok: true, text: async () => svg } }
  try {
    await applyIcon("#00c2b8", { doc, storage: s })
    assert.equal(doc.links.icon.href, svgDataUrl(tintIconSvg(svg, "#00c2b8")))
    assert.equal(s.getItem(ICON_KEY), doc.links.icon.href)
    await applyIcon("#e67326", { doc, storage: s })
    assert.equal(doc.links.icon.href, "./icon.svg")
    assert.equal(doc.links["apple-touch-icon"].href, "./icon-180.png")
    assert.equal(s.getItem(ICON_KEY), null)
  } finally { globalThis.fetch = realFetch }
})

test("paintIcon(null) restores both file icons", () => {
  const doc = fakeDoc()
  paintIcon("data:x", "data:y", doc)
  paintIcon(null, null, doc)
  assert.equal(doc.links.icon.href, "./icon.svg")
  assert.equal(doc.links["apple-touch-icon"].href, "./icon-180.png")
})

test("the boot script sets the saved icon before the app loads", () => {
  const boot = read("../public/theme-boot.js")
  assert.match(boot, new RegExp(`localStorage\\.getItem\\("${ICON_KEY}"\\)`))
  assert.match(boot, /link\[rel="icon"\]/)
  assert.match(read("../main.jsx"), /startAccentIcon\(\)/)
})
