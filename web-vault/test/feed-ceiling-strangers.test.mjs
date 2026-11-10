// Global and Hashtag past the ceiling: their list is the stranger list, which "Older" grows. Uncapped, it went past
// MAX_NOTES while the draw window stops there, so Older kept fetching pages nobody could see and "No older notes" sat
// under note 500 (headless Chrome, 1,500-note fixture, e839b97b). Renders FeedScreen into a small fake DOM where every
// draw is "near the bottom" (the window grows) and Older is always in view (it loads again after each page).
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"

class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); const i = ref ? this.childNodes.indexOf(ref) : -1; i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n); n.parentNode = this; return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener(type, fn) { (this.on ??= {})[type] = fn }
  removeEventListener() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { FeedScreen } = await vite.ssrLoadModule("/src/screens/FeedScreen.jsx")
const { DRAW_NOTES, MAX_NOTES } = await vite.ssrLoadModule("/src/net/feed-window.js")
const { pool } = await vite.ssrLoadModule("/src/net/pool.js")
test.after(() => vite.close())

Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 200; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }
const hex = (n, w = 64) => n.toString(16).padStart(w, "0")
const me = hex(1), friend = hex(2)
const now = Math.floor(Date.now() / 1000)
const TOTAL = 1500

// Always near the bottom, so each draw grows the window (FeedScreen growWindow); Older always in view.
globalThis.document.scrollingElement = { scrollHeight: 100, scrollTop: 0 }
globalThis.IntersectionObserver = class { constructor(fn) { this.fn = fn } observe() { setTimeout(() => this.fn([{ isIntersecting: true }]), 0) } disconnect() {} }
const store = new Map()
globalThis.localStorage = { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: k => store.delete(k) }

function rows(el) {
  const out = []
  const walk = n => { if (n?.attributes?.["data-note-id"]) out.push(n.attributes["data-note-id"]); (n?.childNodes ?? []).forEach(walk) }
  walk(el)
  return out
}
const hasEnd = el => { let found = false; const walk = n => { if (n?.attributes?.class?.includes("feed-end")) found = true; (n?.childNodes ?? []).forEach(walk) }; walk(el); return found }

/** Relays holding TOTAL notes by a follow, all tagged #bench, answering each REQ by until and limit. */
const notes = Array.from({ length: TOTAL }, (_, i) => ({ id: hex(0xbee000 + i), pubkey: friend, kind: 1, created_at: now - 60 - i * 30, tags: [["t", "bench"]], content: `note ${i}`, sig: "" }))
let olderAsks = 0
function mount(choice) {
  store.clear()
  store.set("nv-feed", JSON.stringify(choice))
  olderAsks = 0
  pool.ensureRelay = async () => ({})
  pool.subscribeMany = () => ({ close() {}, params: { onevent() {} } })
  pool.querySync = async (_relays, f) => {
    if (!f.kinds?.includes(1)) return []
    if (f.until) olderAsks++
    return notes.filter(e => (!f.until || e.created_at <= f.until) && (!f.authors || f.authors.includes(e.pubkey)) && (!f["#t"] || e.tags.some(t => t[0] === "t" && f["#t"].includes(t[1])))).slice(0, f.limit ?? 500)
  }
  const el = document.createElement("div")
  const ctx = { vault: { feed: { async event() { return { ok: true } }, async query() { return [] } } }, account: { follows: [friend, hex(3), hex(4), hex(5), hex(6), hex(7)], relays: { read: ["wss://relay.invalid"] }, loaded: true }, session: { pubkey: me } }
  render(h(FeedScreen, { ctx }), el)
  return el
}

for (const choice of [{ mode: "global" }, { mode: "hashtag", tag: "bench" }]) {
  test(`${choice.mode}: Older reaches the oldest note, drawn, with nothing twice and the list held at the ceiling`, async () => {
    const el = mount(choice)
    await until(() => rows(el).length > 0, "the first draw")
    for (let i = 0; i < 400 && !hasEnd(el); i++) await tick(10)
    const drawn = rows(el)
    assert.ok(hasEnd(el), `"No older notes" shows once the relays have nothing older (${olderAsks} Older asks)`)
    assert.equal(new Set(drawn).size, drawn.length, "no note drawn twice")
    assert.equal(drawn.at(-1), notes.at(-1).id, `the last row is the oldest note, not note ${notes.findIndex(n => n.id === drawn.at(-1))}`)
    assert.ok(drawn.length <= MAX_NOTES, `${drawn.length} rows: the list stays under the ceiling`)
    render(null, el)
  })
}
