// New notes go in while the reader stays put (Logen 2026-11-04): components/feed-stay.js finds the post being read and
// holds it at its height after notes are put in above it. Small fake DOM; the window or the desktop pane scrolls.
import test from "node:test"
import assert from "node:assert/strict"
import { readingSpot, holdSpot, pinDelta, AT_TOP_PX } from "../src/components/feed-stay.js"

/** A list of cards, each `h` tall, stacked from `y0`, scrolled by `scroller.y`. Inserting shifts the later ones down. */
function page(ids, { h = 100, y0 = 0, attr = "data-note-id" } = {}) {
  const scroller = { y: 0, calls: [], scrollBy(o) { this.calls.push(o); this.y += o.top }, getBoundingClientRect: () => ({ top: y0 }) }
  const cards = ids.map(id => ({ id, isConnected: true, getAttribute: k => (k === attr ? id : null) }))
  const root = {
    cards,
    layout() { cards.forEach((c, i) => { c.getBoundingClientRect = () => ({ top: y0 + i * h - scroller.y, bottom: y0 + (i + 1) * h - scroller.y }) }) },
    querySelectorAll: sel => (sel === `[${attr}]` ? cards : []),
    querySelector: sel => (sel.startsWith(`[${attr}=`) ? cards.find(c => sel.includes(`"${c.id}"`)) ?? null : null),
    prepend(...ids2) { cards.unshift(...ids2.map(id => ({ id, isConnected: true, getAttribute: k => (k === attr ? id : null) }))); this.layout() },
  }
  root.layout()
  return { root, scroller }
}

test("below the top: the post being read keeps its height when new notes go in above it", () => {
  const { root, scroller } = page(["a", "b", "c", "d", "e", "f"])
  scroller.y = 350 // 3-4 posts down
  root.layout()
  const spot = readingSpot(root, scroller)
  assert.deepEqual(spot, { id: "d", top: -50, attr: "data-note-id" }, "the first card still partly in view")
  root.prepend("n1", "n2") // two new notes above: d moves down 200
  assert.equal(root.querySelector('[data-note-id="d"]').getBoundingClientRect().top, 150)
  const stop = holdSpot(root, scroller, spot)
  stop()
  assert.equal(scroller.y, 550)
  assert.equal(root.querySelector('[data-note-id="d"]').getBoundingClientRect().top, -50, "d is back where it was")
})

test("the window on the phone: the view starts at 0", () => {
  const { root } = page(["a", "b", "c"], { y0: 0 })
  const fakeWindow = { y: 0 }
  globalThis.scrollBy = o => { fakeWindow.y += o.top }
  root.cards.forEach((c, i) => { c.getBoundingClientRect = () => ({ top: i * 100 - 120, bottom: (i + 1) * 100 - 120 }) })
  assert.deepEqual(readingSpot(root, null), { id: "b", top: -20, attr: "data-note-id" })
  delete globalThis.scrollBy
})

test("nothing to hold: no cards, a card gone, or already in place", () => {
  assert.equal(readingSpot({ querySelectorAll: () => [] }, null), null)
  assert.equal(readingSpot(null, null), null)
  const { root, scroller } = page(["a"])
  holdSpot(root, scroller, { id: "gone", top: 0 })()
  assert.equal(scroller.calls.length, 0)
  holdSpot(root, scroller, { id: "a", top: 0 })()
  assert.equal(scroller.calls.length, 0, "already there: no scroll")
  assert.equal(pinDelta({ top: 10 }, 10.5), 0)
  assert.equal(pinDelta({ top: 10 }, 40), 30)
})

test("near the top the list just grows upward (the at-top line is the old 80 px)", () => {
  assert.equal(AT_TOP_PX, 80)
})

test("the Vault list's rows (data-row-id, not notes) are held the same way", () => {
  const { root, scroller } = page(["follow-1", "zap-2", "like-3"], { attr: "data-row-id" })
  scroller.y = 150
  root.layout()
  assert.equal(readingSpot(root, scroller), null, "a Vault row is not a note")
  const spot = readingSpot(root, scroller, { attr: "data-row-id" })
  assert.deepEqual(spot, { id: "zap-2", top: -50, attr: "data-row-id" })
  root.prepend("reply-0")
  holdSpot(root, scroller, spot)()
  assert.equal(scroller.y, 250, "the row being read is back at its height")
})
