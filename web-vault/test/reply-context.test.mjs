// The card's "reply to @name" line and the empty-repost fetch read these (NIP10Thread.parentAuthor, iOS).
import test from "node:test"
import assert from "node:assert/strict"
import { replyToPubkey, repostedId } from "../src/net/thread.js"

const A = "a".repeat(64), B = "b".repeat(64), R = "1".repeat(64), P = "2".repeat(64)
const ev = (tags, kind = 1) => ({ id: "f".repeat(64), kind, tags })

test("a deep reply names the parent's author, not the thread starter", () => {
  // The pubkey on the parent's e tag wins (our composers: parent author first in the p tags).
  assert.equal(replyToPubkey(ev([["e", R, "", "root", A], ["e", P, "", "reply", B], ["p", B], ["p", A]])), B)
  assert.equal(replyToPubkey(ev([["e", R, "", "root", A], ["e", P, "", "reply", B], ["p", A], ["p", B]])), B)
  // No pubkeys on the e tags: the parent's author is appended after the parent's p tags.
  assert.equal(replyToPubkey(ev([["e", R, "", "root"], ["e", P, "", "reply"], ["p", A], ["p", B]])), B)
  assert.equal(replyToPubkey(ev([["e", R], ["e", P], ["p", A], ["p", B]])), B) // old positional tags
  // A bad pubkey slot falls back to the p tags; a mention is never the parent.
  assert.equal(replyToPubkey(ev([["e", R, "", "root"], ["e", P, "", "reply", "npub1x"], ["p", A], ["p", B]])), B)
  assert.equal(replyToPubkey(ev([["e", R, "", "root"], ["e", P, "", "reply", B], ["e", "3".repeat(64), "", "mention", A], ["p", A]])), B)
})

test("a direct reply to the root names the first p tag", () => {
  assert.equal(replyToPubkey(ev([["e", R, "", "root"], ["p", A], ["p", B]])), A)
  assert.equal(replyToPubkey(ev([["e", R], ["p", B]])), B) // old positional tags
  assert.equal(replyToPubkey(ev([["e", R, "", "root", A], ["p", B]])), A)
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
