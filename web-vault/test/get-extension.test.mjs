// Sign-in with no extension: the install card each browser gets (components/GetExtension.jsx installCard), and the
// icon files it points at, which ship in public/ext/ (never hotlinked) and are big enough to stay sharp on a 3x screen.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { existsSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { extensionHelp } from "../src/signer/nip07.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { installCard } = await import("../src/components/GetExtension.jsx")

const UA = {
  chrome: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  edge: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
  firefox: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:144.0) Gecko/20100101 Firefox/144.0",
  safariMac: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
  iphone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
}
const card = (ua, o) => installCard(extensionHelp(ua, o))
const file = src => new URL(`../public/${src.replace(/^\.\//, "")}`, import.meta.url)
const pngSize = buf => [buf.readUInt32BE(16), buf.readUInt32BE(20)]

test("Chrome, Brave and Edge: Sidecar's icon and an Add to <browser> badge for the Chrome Web Store", () => {
  const c = card(UA.chrome)
  assert.equal(c.icon, "./ext/sidecar.png")
  assert.deepEqual(c.badge, { glyph: "./ext/chrome-web-store.png", small: "Chrome Web Store", big: "Add to Chrome" })
  assert.equal(c.line, "Keeps your Nostr key in Chrome and signs for sites like this one.")
  assert.equal(card(UA.chrome, { brave: true }).badge.big, "Add to Brave")
  assert.equal(card(UA.edge).badge.big, "Add to Edge")
})

test("Firefox: Sidecar's icon and an Add to Firefox badge for Firefox Add-ons", () => {
  const c = card(UA.firefox)
  assert.equal(c.icon, "./ext/sidecar.png")
  assert.deepEqual(c.badge, { glyph: "./ext/firefox.svg", small: "Firefox Add-ons", big: "Add to Firefox" })
})

test("Safari: Nostash's app icon and a Get on the App Store badge (Mac App Store on a Mac)", () => {
  const c = card(UA.iphone)
  assert.equal(c.icon, "./ext/nostash.png")
  assert.deepEqual(c.badge, { glyph: "./ext/apple.svg", small: "Get on the", big: "App Store" })
  assert.equal(card(UA.safariMac).badge.big, "Mac App Store")
  assert.equal(card(UA.safariMac).icon, "./ext/nostash.png")
})

test("every icon a card can show is a local file, the app icons 3x their 48 px and the badge glyphs 2x their 26 px", () => {
  const all = [UA.chrome, UA.firefox, UA.safariMac, UA.iphone].map(ua => card(ua))
  for (const src of new Set(all.flatMap(c => [c.icon, c.badge.glyph]))) {
    assert.match(src, /^\.\/ext\//)
    assert.ok(existsSync(file(src)), `${src} is missing`)
    if (src.endsWith(".png")) {
      const [w, h] = pngSize(readFileSync(file(src)))
      assert.equal(w, h, src)
      assert.ok(w >= (src === all[0].badge.glyph ? 52 : 144), `${src} is ${w}px`)
    }
  }
})
