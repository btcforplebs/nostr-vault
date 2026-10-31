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
