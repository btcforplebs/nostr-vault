// Music polish against the iPhone: an album's running time (MusicCount.minutes), the duration kept while a song
// plays (the cover shows it instead), sats as their own orange label, and Clear artists.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { albumMinutes } = await import("../src/readers/MusicScreen.jsx")
const src = readFileSync(new URL("../src/readers/MusicScreen.jsx", import.meta.url), "utf8")

test("an album's running time reads like the iPhone's", () => {
  assert.equal(albumMinutes([{ duration: 125 }, { duration: 200 }]), "5 min")
  assert.equal(albumMinutes([{ duration: 20 }]), "1 min")
  assert.equal(albumMinutes([{ duration: 3600 }, { duration: 300 }]), "1 hr 5 min")
  assert.equal(albumMinutes([{ duration: null }, {}]), null)
  assert.match(src, /wl\.songs\(tracks\.length\), albumMinutes\(tracks\)/)
})

test("a playing song keeps its duration; the cover shows it's on; sats are their own label; Clear artists", () => {
  assert.equal(/"Playing"/.test(src), false)
  assert.match(src, /<span class="muted small">\{wl\.clock\(t\.duration\)\}<\/span>/)
  assert.match(src, /\{on && <span class="music-cover-on"/)
  assert.match(src, /\{t\.sats > 0 && <span class="music-sats small">/)
  assert.match(src, /const clear = \(\) => \{ wl\.clearRecent\(\); setRecent\(\[\]\) \}/)
})
