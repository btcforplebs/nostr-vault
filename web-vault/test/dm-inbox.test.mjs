// The Messages inbox against the iPhone's DMInboxView: one Requests row (below the conversations, with its glyph and
// count), the empty state only when there is nothing at all, and the row polish. Source-level checks: the screen's
// hooks need a signed-in app around them.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"

const src = readFileSync(new URL("../src/screens/MessagesScreen.jsx", import.meta.url), "utf8")

test("one Requests row, the iPhone's (below the list, glyph and count), not a second plain one above it", () => {
  assert.equal(src.match(/href="#\/messages\/requests"/g).length, 1)
  assert.match(src, /class="dm-row dm-requests" href="#\/messages\/requests" aria-label=\{`Requests, \$\{requests\.length\}`\}/)
  assert.doesNotMatch(src, /Requests \(\{requests\.length\}\)/)
})

test("the empty inbox shows only when there are no Requests either (DMInboxView: both lists empty)", () => {
  assert.match(src, /showRequests \? <div class="empty"><strong>No Requests<\/strong><\/div> : requests\.length \? null : \(/)
})

test("inbox row as the iPhone's: unread dot on the face, accent time, count only past 1, two-line preview", () => {
  const css = readFileSync(new URL("../src/styles/dms.css", import.meta.url), "utf8")
  assert.match(src, /\{unread > 0 && <span class="dm-dot" aria-hidden="true" \/>\}/)
  assert.match(src, /\{unread > 1 && <span class="dm-unread">/)
  assert.doesNotMatch(src, /\{unread > 0 && <span class="dm-unread">/)
  assert.match(css, /\.dm-row-last \{[^}]*-webkit-line-clamp: 2/)
  assert.match(css, /\.dm-row\.unread \.dm-time \{ color: var\(--accent\); \}/)
})
