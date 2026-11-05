// The media viewer's swipe up (parity N3): the notes on your vault that use the photo or video on screen, as the
// Vault gallery's "Posted in N notes" (net/media-notes.js).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { swipedUp } from "../src/components/swipe-up.js"

const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")

test("a swipe up is a mostly vertical drag of 70px or more; paging sideways isn't one", () => {
  assert.equal(swipedUp({ x: 100, y: 500 }, { x: 110, y: 400 }), true)
  assert.equal(swipedUp({ x: 100, y: 500 }, { x: 100, y: 450 }), false, "too short")
  assert.equal(swipedUp({ x: 100, y: 500 }, { x: 250, y: 400 }), false, "mostly sideways: paging")
  assert.equal(swipedUp({ x: 100, y: 400 }, { x: 100, y: 500 }), false, "down")
})

test("the viewer shows the notes sheet on a swipe up, ↑ or its button, only with a vault, and reads media-notes.js", () => {
  const lb = src("components/MediaLightbox.jsx")
  assert.match(lb, /const vault = quoteSource\(\)\?\.vault/)
  assert.match(lb, /swipedUp\(touch\.current, \{ x: t\.clientX, y: t\.clientY \}\)\) setNotes\(true\)/)
  assert.match(lb, /e\.key === "ArrowUp" && vault/)
  assert.match(lb, /\{vault && notes && items\[at\] && <MediaNotesSheet vault=\{vault\} item=\{items\[at\]\}/)
  assert.match(lb, /if \(notesRef\.current\) setNotes\(false\); else onClose\(\)/, "Esc puts the sheet away first")
  const sheet = src("components/MediaNotesSheet.jsx")
  assert.match(sheet, /vaultNotesUsing\(vault, \{ url: item\.url, sha256: item\.x \}\)/)
  assert.match(sheet, /Posted in \$\{notes\.length === 1 \? "1 note"/)
  assert.match(sheet, /href=\{`#\/thread\/\$\{note\.id\}`\}/)
})
