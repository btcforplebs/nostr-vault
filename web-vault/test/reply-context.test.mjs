// The card's "reply to @name" line and the empty-repost fetch read these (FeedServiceTypes.replyToPubkey, iOS).
import test from "node:test"
import assert from "node:assert/strict"
import { replyToPubkey, repostedId } from "../src/net/thread.js"

const A = "a".repeat(64), B = "b".repeat(64), R = "1".repeat(64), P = "2".repeat(64)
const ev = (tags, kind = 1) => ({ id: "f".repeat(64), kind, tags })

test("a reply names the first p tag, as the iPhone does", () => {
  assert.equal(replyToPubkey(ev([["e", R, "", "root"], ["e", P, "", "reply"], ["p", A], ["p", B]])), A)
  assert.equal(replyToPubkey(ev([["e", R], ["p", B]])), B) // old positional tags
})

test("not a reply: no line", () => {
  assert.equal(replyToPubkey(ev([["p", A]])), null) // a mention, no e
  assert.equal(replyToPubkey(ev([["e", R, "", "mention"], ["p", A]])), null) // a quote
  assert.equal(replyToPubkey(ev([["e", R], ["p", A]], 6)), null) // a repost
  assert.equal(replyToPubkey(ev([["e", R, "", "reply"]])), null) // names nobody
})

test("a repost's e tag is the note it points at", () => {
  assert.equal(repostedId(ev([["e", R, "wss://r"], ["p", A]], 6)), R)
  assert.equal(repostedId(ev([["p", A]], 6)), null)
  assert.equal(repostedId(ev([["e", "nothex"]], 6)), null)
})
