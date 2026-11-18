// Off-screen Feed cards skip drawing only once drawn and measured (src/components/card-sizes.js): a card never measured
// stays drawn in full, a measured one gets its own content height as the placeholder, written once.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { watchCardSizes } from "../src/components/card-sizes.js"

let ro, mo
class FakeRO { constructor(cb) { this.cb = cb; this.seen = new Set(); ro = this } observe(el) { this.seen.add(el) } unobserve(el) { this.seen.delete(el) } disconnect() { this.seen.clear() } }
class FakeMO { constructor(cb) { this.cb = cb; mo = this } observe() {} disconnect() {} }
globalThis.ResizeObserver = FakeRO
globalThis.MutationObserver = FakeMO
globalThis.CSS = { supports: (p, v) => p === "content-visibility" && v === "auto" }

const card = id => {
  const props = new Map()
  return { nodeType: 1, isConnected: true, dataset: { noteId: id }, classList: { contains: c => c === "note-card" },
    style: { setProperty: (k, v) => props.set(k, v) }, props }
}
const header = { nodeType: 1, dataset: {}, classList: { contains: () => false } }
// contentRect is the content box (contain-intrinsic-size sizes the content; padding and border are added to it).
const resize = (el, h) => ro.cb([{ target: el, contentRect: { height: h }, borderBoxSize: [{ blockSize: h + 31 }] }])

test("a card is drawn in full until measured, then skips with its own content height, written once", () => {
  const a = card("a"), main = { children: [header, a] }
  const stop = watchCardSizes(main)
  assert.equal(a.dataset.cv, undefined, "never measured: no rule, no guessed height")
  assert.ok(ro.seen.has(a) && !ro.seen.has(header))
  resize(a, 259.6)
  assert.equal(a.dataset.cv, "")
  assert.equal(a.props.get("--card-h"), "260px", "the content box, not the border box")
  assert.ok(!ro.seen.has(a), "not watched again: the browser's `auto` keeps the drawn size from here")
  stop()
})

test("a card drawn again (Back remounts the Feed) or added later is measured before it skips", () => {
  const again = card("a")
  const stop = watchCardSizes({ children: [header, again] })
  assert.equal(again.dataset.cv, undefined)
  const later = card("b")
  mo.cb([{ addedNodes: [later], removedNodes: [] }])
  assert.ok(ro.seen.has(later) && later.dataset.cv === undefined)
  resize(later, 377)
  assert.equal(later.props.get("--card-h"), "377px")
  mo.cb([{ addedNodes: [], removedNodes: [again] }])
  assert.ok(!ro.seen.has(again))
  stop()
})

test("the rule is in note-card.css and off while a menu or picker is open", () => {
  const css = readFileSync(new URL("../src/styles/note-card.css", import.meta.url), "utf8")
  assert.match(css, /\.note-card\[data-cv\] \{ content-visibility: auto; contain-intrinsic-size: auto var\(--card-h\); \}/)
  assert.match(css, /\.note-card\[data-cv\]:has\(\.more-menu, \.tapback, \.zap-picker, \.zap-error, \.quick-menu\) \{ content-visibility: visible; \}/)
  const feed = readFileSync(new URL("../src/screens/FeedScreen.jsx", import.meta.url), "utf8")
  assert.match(feed, /useCardSizes\(screen, !Reader && !media && layout === "expanded"\)/)
})
