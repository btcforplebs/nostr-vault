// A3 (Messages UX check 2026-11-18): the classic chat follows new messages to the bottom only while you are there,
// or for your own just-sent one; reading older messages (or after Open more) nothing moves you.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { followsEnd } from "../src/components/chat-scroll.js"

const ME = "a".repeat(64), BOB = "b".repeat(64)

test("follows the end at the bottom, or for your own message being sent; not while reading older ones", () => {
  assert.equal(followsEnd(true, { from: BOB }, ME), true)
  assert.equal(followsEnd(false, { from: BOB }, ME), false, "theirs lands while you read older ones: you stay")
  assert.equal(followsEnd(false, { from: ME, pending: true }, ME), true, "you just sent")
  assert.equal(followsEnd(false, { from: ME }, ME), false, "an old one of yours (Open more) doesn't pull you down")
  assert.equal(followsEnd(false, undefined, ME), false)
})

test("the conversation uses it and no longer scrolls to the end on every new row", () => {
  const src = readFileSync(new URL("../src/screens/ConversationScreen.jsx", import.meta.url), "utf8")
  assert.match(src, /useChatScroll\(\{ end, thread, rows, me, key: peer \}\)/)
  assert.doesNotMatch(src, /scrollIntoView\?\.\(\{ block: "end" \}\) \}, \[rows\.length\]\)/)
  assert.match(src, /data-id=\{m\.id\}/, "each row is findable to keep the one being read in place")
})
