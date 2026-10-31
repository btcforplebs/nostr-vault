// Article comments and highlights drop spam as the iPhone does (FeedNote.isNoiseOrSpam, ArticleReaderView): every
// branch of the port, then the tally and highlights using it.
import test from "node:test"
import assert from "node:assert/strict"
import { isNoiseOrSpam } from "../src/readers/spam.js"
import * as en from "../src/readers/engagement.js"

test("empty or blank is noise", () => {
  assert.equal(isNoiseOrSpam(""), true)
  assert.equal(isNoiseOrSpam("  \n\t "), true)
  assert.equal(isNoiseOrSpam(undefined), true)
})

test("JSON and wallet-connect payloads are noise", () => {
  assert.equal(isNoiseOrSpam(' {"a":1} '), true)
  assert.equal(isNoiseOrSpam("pay via nostr-wallet-connect now"), true)
  assert.equal(isNoiseOrSpam('reply "method": "pay_invoice"'), true)
  assert.equal(isNoiseOrSpam('the "result": ok'), true)
  assert.equal(isNoiseOrSpam("NIP47 thing"), true)
  assert.equal(isNoiseOrSpam("{ this is a brace but no close"), false)
})

test("20 of one character in a row is noise, 19 isn't; emoji count as one character each", () => {
  assert.equal(isNoiseOrSpam("a".repeat(20)), true)
  assert.equal(isNoiseOrSpam("a".repeat(19)), false)
  assert.equal(isNoiseOrSpam("🔥".repeat(20)), true)
  assert.equal(isNoiseOrSpam("🔥".repeat(19)), false)
  assert.equal(isNoiseOrSpam("👍🏽".repeat(19)), false) // a skin-tone emoji is one character, not two
  assert.equal(isNoiseOrSpam("ab".repeat(30)), false)
})

test("a short post with more than 6 hashtags, or more than 6 mentions when not a reply, is spam", () => {
  const t = n => Array.from({ length: n }, (_, i) => ["t", `tag${i}`])
  const p = n => Array.from({ length: n }, (_, i) => ["p", String(i).repeat(64).slice(0, 64)])
  assert.equal(isNoiseOrSpam("short", t(7)), true)
  assert.equal(isNoiseOrSpam("short", t(6)), false)
  assert.equal(isNoiseOrSpam("ab ".repeat(34), t(7)), false) // 100+ characters: not counted
  assert.equal(isNoiseOrSpam("short", p(7)), true)
  assert.equal(isNoiseOrSpam("short", [["e", "a".repeat(64), "", "reply"], ...p(7)]), false) // a reply tags everyone
  assert.equal(isNoiseOrSpam("short", [["e", "a".repeat(64)], ...p(7)]), false) // an unmarked e is a reply too
  assert.equal(isNoiseOrSpam("short", [["e", "a".repeat(64), "", "mention"], ...p(7)]), true) // a mention isn't
})

test("bot status and scam phrases are spam, in any case", () => {
  for (const k of ["Relay status: up", "relay uptime: 99%", "Ping time: 3ms", "BLOCK HEIGHT: 900000", "free bitcoin here",
    "earn double bitcoin", "join our telegram channel for free", "pump telegram", "WhatsApp group", "Click here to claim"]) {
    assert.equal(isNoiseOrSpam(k), true, k)
  }
  assert.equal(isNoiseOrSpam("A thoughtful comment about the article."), false)
})

const ID = "a".repeat(64), AUTHOR = "b".repeat(64), COORD = `30023:${AUTHOR}:my-post`, NOW = 1_800_000_000
let n = 0
const ev = (kind, tags, content) => ({ id: `ev${++n}`, kind, pubkey: `p${n}`, content, tags, created_at: 1_700_000_000 + n })

test("spam comments and spam highlights don't show or count; likes and zaps aren't touched", () => {
  const evs = [
    ev(1111, [["a", COORD]], "Great read"),
    ev(1111, [["a", COORD]], "free bitcoin, click here to claim"),
    ev(1, [["e", ID, "", "root"]], "🔥".repeat(25)),
    ev(1, [["e", ID, "", "root"]], "Agreed"),
    ev(7, [["e", ID]], "+"),
    ev(9802, [["a", COORD]], "A line worth keeping."),
    ev(9802, [["a", COORD]], '{"method":"pay"}'),
  ]
  const t = en.tally(evs, ID, COORD, NOW)
  assert.equal(t.commentCount, 2)
  assert.deepEqual(t.topLevel.map(e => e.content), ["Great read", "Agreed"])
  assert.equal(t.likers.size, 1)
  assert.deepEqual(en.shownHighlights(evs, ID, COORD, NOW).map(h => h.passage), ["A line worth keeping."])
})
