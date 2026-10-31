// A live stream inside a note is the Live tile, ENDED once off air (LiveStreamEmbedView). Pure parts here; the tile
// itself was checked in headless Chrome (on-air LIVE tile, ENDED dimmed tile).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({ load(url, context, next) {
  if (!url.endsWith(".jsx")) return next(url, context)
  const { code } = transformSync(fileURLToPath(url), readFileSync(fileURLToPath(url), "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
  return { format: "module", source: code, shortCircuit: true }
} })
const { embeddedStream } = await import("../src/readers/LiveEmbed.jsx")
const { isPlayableLive } = await import("../src/readers/live.js")

const NOW = 1_800_000_000
const stream = (tags, at = NOW - 60) => ({ id: "e".repeat(64), kind: 30311, pubkey: "a".repeat(64), created_at: at, content: "",
  tags: [["d", "show"], ["title", "Morning show"], ["streaming", "https://cdn.example/live.m3u8"], ...tags] })

test("a 30311 is a stream to embed; anything else isn't", () => {
  const s = embeddedStream(stream([["status", "live"]]))
  assert.equal(s.title, "Morning show")
  assert.equal(s.address, `30311:${"a".repeat(64)}:show`)
  assert.equal(embeddedStream({ ...stream([]), kind: 1 }), null)
  assert.equal(embeddedStream({ ...stream([]), tags: [] }), null) // no d tag
  assert.equal(embeddedStream(null), null)
})

test("on air plays; ended, stale, or with nothing to play shows ENDED", () => {
  assert.equal(isPlayableLive(embeddedStream(stream([["status", "live"]])), NOW), true)
  assert.equal(isPlayableLive(embeddedStream(stream([["status", "ended"]])), NOW), false)
  assert.equal(isPlayableLive(embeddedStream(stream([["status", "live"]], NOW - 2 * 3600)), NOW), false) // not republished in an hour
  assert.equal(isPlayableLive(embeddedStream({ ...stream([["status", "live"]]), tags: [["d", "x"], ["status", "live"]] }), NOW), false)
})

test("the quote card hands a stream to the embed, and the tile has an ENDED state that can't be tapped", () => {
  const quoted = readFileSync(new URL("../src/components/QuotedNote.jsx", import.meta.url), "utf8")
  assert.match(quoted, /const stream = embeddedStream\(ev\)\n\s*if \(stream\) return <LiveEmbed stream=\{stream\} \/>/)
  const live = readFileSync(new URL("../src/readers/LiveScreen.jsx", import.meta.url), "utf8")
  assert.match(live, /if \(ended\) onOpen = null/)
  assert.match(live, /<span class="live-badge live-ended">ENDED<\/span>/)
  const embed = readFileSync(new URL("../src/readers/LiveEmbed.jsx", import.meta.url), "utf8")
  assert.match(embed, /<LiveTile stream=\{stream\} ended=\{!live\}/)
  assert.match(embed, /\{playing && live && ctx && <LiveSheet/)
})
