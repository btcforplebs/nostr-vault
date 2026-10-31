// Article engagement, read-only: likes, comments, zaps and highlights counted as the iPhone counts them
// (ArticleTallyTests, ArticleHighlightTests, ArticleBlockFilterTests).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"
import { finalizeEvent, generateSecretKey } from "nostr-tools/pure"
import { npubEncode } from "nostr-tools/nip19"
import * as en from "../src/readers/engagement.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})

const ID = "a".repeat(64), AUTHOR = "b".repeat(64)
const COORD = `30023:${AUTHOR}:my-post`
const NOW = 1_800_000_000
let n = 0
const ev = (kind, tags, { content = "hi", pubkey, at = 1_700_000_000 } = {}) => { n++; return { id: `ev${n}`, kind, pubkey: pubkey ?? `p${n}`, content, tags, created_at: at + n } }
const tally = evs => en.tally(evs, ID, COORD, NOW)

test("the article's coordinate, null without a d tag", () => {
  assert.equal(en.coordinate({ kind: 30023, pubkey: AUTHOR, tags: [["d", "my-post"]] }), COORD)
  assert.equal(en.coordinate({ kind: 30023, pubkey: AUTHOR, tags: [] }), null)
})

test("likes count people, not reactions, and skip dislikes and other targets", () => {
  const t = tally([
    ev(7, [["a", COORD]], { content: "+", pubkey: "alice" }), ev(7, [["e", ID]], { content: "🔥", pubkey: "alice" }),
    ev(7, [["e", ID]], { content: "+", pubkey: "bob" }), ev(7, [["e", ID]], { content: "-", pubkey: "carol" }),
    ev(7, [["e", "other"]], { content: "+", pubkey: "dave" }),
  ])
  assert.deepEqual([...t.likers].sort(), ["alice", "bob"])
})

test("zaps sum the sats of receipts that point here (requested amount, else the invoice)", () => {
  // A real signed zap request (throwaway key): an unsigned one counts for nothing.
  const request = JSON.stringify(finalizeEvent({ kind: 9734, created_at: 1_700_000_000, content: "", tags: [["p", AUTHOR], ["amount", "21000"]] }, generateSecretKey()))
  const t = tally([
    ev(9735, [["e", ID], ["p", AUTHOR], ["description", request]]),
    ev(9735, [["a", COORD], ["bolt11", "lnbc10u1pxyz"]]),
    ev(9735, [["e", "other"], ["description", request]]),
  ])
  assert.equal(t.zaps, 2)
  assert.equal(t.zapSats, 21 + 1000)
})

test("comments: NIP-22 and kind 1, top-level vs replies, mentions don't count", () => {
  const top = ev(1111, [["A", COORD], ["K", "30023"], ["a", COORD], ["k", "30023"]])
  const reply = ev(1111, [["A", COORD], ["K", "30023"], ["e", top.id], ["k", "1111"]])
  const legacy = ev(1, [["e", ID, "", "root"], ["a", COORD]])
  const legacyReply = ev(1, [["e", ID, "", "root"], ["e", legacy.id, "", "reply"]])
  const mention = ev(1, [["e", ID, "", "mention"]])
  const elsewhere = ev(1111, [["A", "30023:x:y"], ["e", "nope"]])
  const t = tally([top, reply, legacy, legacyReply, mention, elsewhere])
  assert.equal(t.commentCount, 4)
  assert.deepEqual(t.topLevel.map(e => e.id), [top.id, legacy.id])
  assert.equal(t.replyCounts.get(top.id), 1)
  assert.equal(t.replyCounts.get(legacy.id), 1)
})

test("top-level comments come oldest first", () => {
  const late = ev(1111, [["a", COORD]], { at: 1_700_000_500 }), early = ev(1111, [["a", COORD]], { at: 1_600_000_000 })
  assert.deepEqual(tally([late, early]).topLevel.map(e => e.id), [early.id, late.id])
})

test("duplicates and future-dated events are dropped", () => {
  const like = ev(7, [["e", ID]], { pubkey: "alice" })
  const future = ev(1111, [["a", COORD]], { at: 2_000_000_000 })
  const t = tally([like, like, future])
  assert.equal(t.likers.size, 1)
  assert.equal(t.commentCount, 0)
})

test("filters ask by id, coordinate and the NIP-22 root; only by id without a coordinate", () => {
  const f = en.engagementFilters(ID, COORD)
  assert.ok(f.some(x => x["#E"]?.[0] === ID))
  assert.ok(f.some(x => x["#A"]?.[0] === COORD))
  assert.equal(en.engagementFilters(ID, null).length, 2)
  assert.deepEqual(en.highlightFilters(ID, COORD).map(x => Object.keys(x).find(k => k.startsWith("#"))), ["#a", "#e"])
  assert.equal(en.highlightFilters(ID, null).length, 1)
})

test("a highlight counts by coordinate or version id, needs a passage, and refuses other targets", () => {
  assert.equal(en.highlight(ev(9802, [["a", COORD]], { content: " A line. " }), ID, COORD, NOW).passage, "A line.")
  assert.ok(en.highlight(ev(9802, [["e", ID]], { content: "x" }), ID, COORD, NOW))
  assert.equal(en.highlight(ev(9802, [["e", "other"]], { content: "x" }), ID, COORD, NOW), null)
  assert.equal(en.highlight(ev(9802, [["e", ID]], { content: "  " }), ID, COORD, NOW), null)
  assert.equal(en.highlight(ev(1, [["e", ID]], { content: "x" }), ID, COORD, NOW), null)
  assert.equal(en.highlight(ev(9802, [["e", ID], ["comment", "  so true "]], { content: "x" }), ID, COORD, NOW).comment, "so true")
})

test("an overlong passage isn't a highlight; one dated in the future is refused", () => {
  // "xy", not one letter: 20 of one character in a row is spam (spam.js).
  assert.equal(en.highlight(ev(9802, [["e", ID]], { content: "xy".repeat(en.MAX_PASSAGE / 2) + "x" }), ID, COORD, NOW), null)
  assert.ok(en.highlight(ev(9802, [["e", ID]], { content: "xy".repeat(en.MAX_PASSAGE / 2) }), ID, COORD, NOW))
  assert.equal(en.highlight(ev(9802, [["e", ID]], { content: "x", at: NOW + 3600 }), ID, COORD, NOW), null)
  assert.ok(en.highlight(ev(9802, [["e", ID]], { content: "x", at: NOW + 60 - n }), ID, COORD, NOW), "clock drift allowed")
})

test("four hundred highlights show the newest fifty, once each", () => {
  const hs = Array.from({ length: 400 }, (_, i) => ({ id: `h${i}`, kind: 9802, pubkey: "p", content: `p${i}`, tags: [["e", ID]], created_at: 1_700_000_000 + i }))
  const shown = en.shownHighlights([...hs, hs[399]], ID, COORD, NOW)
  assert.equal(shown.length, en.MAX_HIGHLIGHTS)
  assert.equal(shown[0].id, "h399")
  assert.equal(new Set(shown.map(h => h.id)).size, shown.length)
})

test("blocked people's likes, comments and highlights are out; zap receipts stay", () => {
  const evs = [ev(7, [["e", ID]], { pubkey: "bad" }), ev(9735, [["e", ID]], { pubkey: "bad" }), ev(1111, [["a", COORD]], { pubkey: "good" })]
  assert.deepEqual(en.visibleEvents(evs, new Set(["bad"])).map(e => e.kind), [9735, 1111])
  assert.equal(en.visibleEvents(evs, new Set()).length, 3)
})

test("relays: your read relays then the author's write relays, once each, at most 8", () => {
  assert.deepEqual(en.engagementRelays(["wss://a/", "wss://b"], ["wss://A", "wss://c"]), ["wss://a/", "wss://b", "wss://c"])
  assert.equal(en.engagementRelays(Array.from({ length: 12 }, (_, i) => `wss://r${i}`)).length, 8)
})

const walk = (node, out = []) => {
  if (node == null || typeof node === "boolean") return out
  if (Array.isArray(node)) { node.forEach(x => walk(x, out)); return out }
  if (typeof node !== "object") { out.push(String(node)); return out }
  out.push(node)
  if (["AuthorName", "Avatar", "Mention"].includes(node.type?.name)) return out // hooks
  if (typeof node.type === "function") walk(node.type(node.props), out)
  else walk(node.props?.children, out)
  return out
}
const text = node => walk(node).filter(x => typeof x === "string").join("")
const { EngagementView } = await import("../src/readers/Engagement.jsx")
const article = { id: ID, kind: 30023, pubkey: AUTHOR, tags: [["d", "my-post"]] }

test("the section: counts, highlights with their comment, comments with reply counts", () => {
  const now = Math.floor(Date.now() / 1000) - 1000
  const top = ev(1111, [["a", COORD]], { content: "Great read", at: now })
  const evs = [
    ev(7, [["e", ID]], { pubkey: "alice", at: now }), ev(7, [["e", ID]], { pubkey: "bob", at: now }),
    top, ev(1111, [["A", COORD], ["e", top.id]], { at: now }),
    ev(9802, [["a", COORD], ["comment", "so true"]], { content: "A line worth keeping.", at: now }),
  ]
  const t = text(EngagementView({ article, events: evs }))
  assert.match(t, /2 likes · 2 comments · 1 highlight/)
  assert.match(t, /Highlights · 1/)
  assert.match(t, /A line worth keeping\./)
  assert.match(t, /so true/)
  assert.match(t, /Comments · 2/)
  assert.match(t, /Great read/)
  assert.match(t, /1 reply/)
})

test("comment text is drawn as a note's is: nostr:npub becomes the person's name, links stay links", () => {
  const now = Math.floor(Date.now() / 1000) - 1000
  const npub = npubEncode("b".repeat(64))
  const c = ev(1111, [["a", COORD]], { content: `Agree with nostr:${npub} see https://example.com/post`, at: now })
  const nodes = walk(EngagementView({ article, events: [c] }))
  const t = nodes.filter(x => typeof x === "string").join("")
  assert.doesNotMatch(t, /nostr:npub/)
  assert.ok(nodes.some(x => x?.type?.name === "Mention" && x.props.pubkey === "b".repeat(64)))
  assert.ok(nodes.some(x => x?.type === "a" && x.props.href === "https://example.com/post"))
})

test("nothing yet says so; the section offers no like, comment or zap button (read-only)", () => {
  const nodes = walk(EngagementView({ article, events: [] }))
  assert.match(nodes.filter(x => typeof x === "string").join(""), /No likes or comments yet/)
  const src = readFileSync(new URL("../src/readers/Engagement.jsx", import.meta.url), "utf8")
  assert.equal(/<button|signEvent|publish\(|\bzap\(/.test(src), false)
})

test("the reader shows the section, after the body", () => {
  assert.match(readFileSync(new URL("../src/readers/ArticlesScreen.jsx", import.meta.url), "utf8"), /<Markdown body=\{event\.content\} \/>\}\n\s*\{ctx && <ArticleEngagement ctx=\{ctx\} article=\{event\} \/>\}/)
})
