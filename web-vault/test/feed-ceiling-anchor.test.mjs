// Following's Older at the 500-note ceiling: once the list is full, each Older page drops the newest notes (capOlder),
// all of them above the reader. Unpinned, the page jumped up by their height (nv-parity 2026-11-10). Renders FeedScreen
// into a fake DOM with layout: every note card is H px tall, stacked in document order under the window's scrollY, so
// readingSpot, holdSpot and the window's scrollBy see where each card is.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"

const H = 100
let mounted = null
/** Every note card under `el`, in document order. */
function cards(el, out = []) {
  if (el?.attributes?.["data-note-id"]) out.push(el)
  for (const c of el?.childNodes ?? []) cards(c, out)
  return out
}
const attrSel = sel => /^\[([\w-]+)(?:="([^"]*)")?\]$/.exec(sel)
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get isConnected() { let n = this; while (n.parentNode) n = n.parentNode; return n === mounted }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); const i = ref ? this.childNodes.indexOf(ref) : -1; i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n); n.parentNode = this; return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  getAttribute(k) { return this.attributes[k] ?? null }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { (this.on ??= {})[type] = fn }
  removeEventListener() {}
  closest() { return null } // no desktop pane: the Feed scrolls in the window
  querySelectorAll(sel) {
    const m = attrSel(sel)
    if (!m) return []
    const out = []
    const walk = n => { for (const c of n.childNodes) { if (c.attributes?.[m[1]] != null && (m[2] == null || c.attributes[m[1]] === m[2])) out.push(c); walk(c) } }
    walk(this)
    return out
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] ?? null }
  /** A card's place: its index among the cards on the page times H, less the window's scroll. */
  getBoundingClientRect() {
    const i = cards(mounted).indexOf(this)
    const top = i * H - globalThis.scrollY
    return { top, bottom: top + H, height: H }
  }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
  scrollingElement: { scrollHeight: 100, scrollTop: 0 }, // always near the bottom: the draw window grows to the list
}
globalThis.scrollY = 0
globalThis.innerHeight = 800
globalThis.scrollBy = ({ top }) => { globalThis.scrollY += top }
// Older loads when its button is in view: here only when the test says so.
const observers = new Set()
globalThis.IntersectionObserver = class {
  constructor(fn) { this.fn = fn }
  observe() { observers.add(this) }
  disconnect() { observers.delete(this) }
}
const fireOlder = () => { for (const o of [...observers]) o.fn([{ isIntersecting: true }]) }

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { FeedScreen } = await vite.ssrLoadModule("/src/screens/FeedScreen.jsx")
const { MAX_NOTES } = await vite.ssrLoadModule("/src/net/feed-window.js")
const { pool } = await vite.ssrLoadModule("/src/net/pool.js")
test.after(() => vite.close())

Object.defineProperty(globalThis.navigator, "onLine", { value: false, configurable: true }) // Haven only: no relay top-up
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 400; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }
const hex = (n, w = 64) => n.toString(16).padStart(w, "0")
const me = hex(1)
const now = Math.floor(Date.now() / 1000)
const TOTAL = 1200
const evs = Array.from({ length: TOTAL }, (_, i) => ({ id: hex(0xcab000 + i), pubkey: me, kind: 1, created_at: now - 60 - i * 30, tags: [], content: `note ${i}`, sig: "" }))

test("Following's Older keeps the note being read where it is when the ceiling drops the newest", async () => {
  pool.ensureRelay = async () => ({})
  pool.querySync = async () => []
  pool.subscribeMany = () => ({ close() {}, params: { onevent() {} } })
  const vault = { feed: { async event() { return { ok: true } }, async query(f) { return evs.filter(e => f.kinds.includes(e.kind) && (!f.until || e.created_at <= f.until)).slice(0, f.limit ?? 500) } } }
  const el = document.createElement("div")
  mounted = el
  render(h(FeedScreen, { ctx: { vault, account: { follows: [me], relays: { read: [] }, loaded: true }, session: { pubkey: me } } }), el)
  await until(() => cards(el).length > 0, "the first draw")

  let crossed = 0
  for (let step = 0; step < 30 && crossed < 3; step++) {
    const before = cards(el)
    const head = before[0].attributes["data-note-id"], count = before.length
    // The reader near the bottom of what is drawn, at a card's edge.
    globalThis.scrollY = Math.max(0, (count - 4) * H)
    const reading = before[count - 4].attributes["data-note-id"]
    fireOlder()
    await until(() => cards(el).length !== count || cards(el)[0].attributes["data-note-id"] !== head, `Older page ${step + 1}`)
    await tick(10) // the layout effect's pin, and the draw window catching up
    const after = cards(el)
    const card = after.find(c => c.attributes["data-note-id"] === reading)
    assert.ok(card, `the note being read is still drawn after Older page ${step + 1}`)
    const dropped = after[0].attributes["data-note-id"] !== head
    if (dropped) crossed++
    assert.equal(card.getBoundingClientRect().top, 0, `Older page ${step + 1}${dropped ? " (past the ceiling: the newest dropped)" : ""} moved the note being read`)
    assert.ok(after.length <= MAX_NOTES, `${after.length} rows`)
  }
  assert.ok(crossed >= 2, `Older crossed the ceiling (${crossed} pages dropped the head)`)
  render(null, el)
})
