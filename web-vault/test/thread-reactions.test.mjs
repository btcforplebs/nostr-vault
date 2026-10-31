// The thread's focused note shows a reaction summary as the iPhone's does (❤️ 3 👀 1 · ↻ 1). Lane E of the web UI
// match (RESEARCH/NV_WEB_UI_MATCH_IPHONE.md). Test keys only.
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
const { reactionSummary } = await import("../src/screens/ThreadScreen.jsx")

const note = "a".repeat(64)
let n = 0
const ev = (kind, pubkey, content = "", tags = [["e", note]]) => ({ id: String(++n).padStart(64, "0"), kind, pubkey, content, tags })

test("each emoji with how many people sent it, most first, then reposts", () => {
  const sum = reactionSummary([
    ev(7, "p1", "+"), ev(7, "p2", ""), ev(7, "p3", "❤️"), // "+" and empty are a like: three ❤️
    ev(7, "p1", "👀"),
    ev(7, "p1", "👀"), // the same person twice counts once
    ev(7, "p4", "-"), // a dislike is not shown
    ev(6, "p5"), ev(6, "p5"), ev(6, "p6"),
  ], note)
  assert.deepEqual(sum.reactions, [{ emoji: "❤️", count: 3 }, { emoji: "👀", count: 1 }])
  assert.equal(sum.reposts, 2)
})

test("only events that name the note count, and each event once", () => {
  const other = ev(7, "p1", "🔥", [["e", "b".repeat(64)]]) // a relay answered the tag filter loosely
  const twice = ev(7, "p2", "🔥")
  const sum = reactionSummary([other, twice, twice, ev(1, "p3", "a reply")], note)
  assert.deepEqual(sum.reactions, [{ emoji: "🔥", count: 1 }])
  assert.equal(sum.reposts, 0)
})

test("your own reaction counts at once, in place of what the relays had for you, and goes when taken back", () => {
  const relays = [ev(7, "p1", "+"), ev(7, "me", "😂"), ev(6, "p5")]
  // Liked just now: counted before any relay has it.
  assert.deepEqual(reactionSummary([], note, { pubkey: "me", emoji: "❤️" }).reactions, [{ emoji: "❤️", count: 1 }])
  // Swapped 😂 for 🔥: the old one isn't counted twice.
  assert.deepEqual(reactionSummary(relays, note, { pubkey: "me", emoji: "🔥" }).reactions, [{ emoji: "❤️", count: 1 }, { emoji: "🔥", count: 1 }])
  // A heart joins the other hearts.
  assert.deepEqual(reactionSummary(relays, note, { pubkey: "me", emoji: "❤️" }).reactions, [{ emoji: "❤️", count: 2 }])
  // Taken back (or failed): gone, and an emoji nobody else sent drops out.
  assert.deepEqual(reactionSummary(relays, note, { pubkey: "me", emoji: null }).reactions, [{ emoji: "❤️", count: 1 }])
  // Not changed here: the relays' answer stands.
  assert.deepEqual(reactionSummary(relays, note, null).reactions, [{ emoji: "❤️", count: 1 }, { emoji: "😂", count: 1 }])
})

test("the thread screen draws the focused note, its summary and the REPLIES label", () => {
  const src = readFileSync(new URL("../src/screens/ThreadScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /class="note-card focused"/)
  assert.match(src, /<ReactionSummary /)
  assert.match(src, /class="thread-replies-label">Replies</)
  assert.match(src, /class="thread-done"/)
  assert.match(src, />Done<\/button>/)
})
