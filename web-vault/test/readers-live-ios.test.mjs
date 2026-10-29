// Live against the iPhone: the empty states say who was asked about (LiveChat.emptyLiveText) with Show Global streams /
// Try again, "Untitled stream", LIVE and viewers together on the tile, a time on each chat line, a failed load ends.
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
const { liveEmpty, chatTime } = await import("../src/readers/LiveScreen.jsx")
const src = readFileSync(new URL("../src/readers/LiveScreen.jsx", import.meta.url), "utf8")

test("empty Live says who was asked about, as the iPhone does", () => {
  const f = ["a".repeat(64)]
  assert.deepEqual(liveEmpty({ scope: "following", follows: [], failed: false }), { title: "Nobody you follow is live", message: "You don't follow anyone yet. Global shows everyone who is streaming.", action: "global" })
  assert.equal(liveEmpty({ scope: "global", follows: f, failed: true }).title, "Could not reach any relay")
  assert.equal(liveEmpty({ scope: "following", follows: f, failed: false }).action, "global")
  assert.equal(liveEmpty({ scope: "global", follows: f, failed: false }).title, "Nobody in your network is live")
  assert.equal(liveEmpty({ scope: "global", follows: [], failed: false }).title, "Nothing live right now")
  assert.equal(liveEmpty({ scope: "global", follows: [], failed: false }).action, "retry")
})

test("chat lines carry a short time", () => {
  assert.match(chatTime(1_800_000_000, "en-US"), /^\d{1,2}:\d{2}\s?[AP]M$/)
  const chat = readFileSync(new URL("../src/readers/LiveChat.jsx", import.meta.url), "utf8")
  assert.match(chat, /<time class="live-time"[^>]*>\{chatTime\(r\.at\)\}<\/time>/)
})

test("tiles: Untitled stream, LIVE and viewers together top-left; Global without follows says it's unfiltered; a failed load ends", () => {
  assert.equal(/"Live stream"/.test(src), false)
  assert.match(src, /<span class="live-pills"><span class="live-badge">/)
  assert.match(src, /Unfiltered: people you don't know yet/)
  assert.match(src, /setFailed\(true\); setStreams\(\[\]\)/)
})
