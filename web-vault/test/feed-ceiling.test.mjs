// The Feed's ceiling and draw window, on the screen itself (Spec 2): a long feed must not put every note in the DOM,
// and it must not cut the list at the window either. Renders FeedScreen into the same small fake DOM the first-sync
// test uses, with a vault that answers with more notes than were asked for (a Haven page is not trusted to be small).
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
const me = hex(1)
const now = Math.floor(Date.now() / 1000)

/** Every row the screen drew: the note cards carry data-note-id. */
function rows(el) {
  const out = []
  const walk = n => { if (n?.attributes?.["data-note-id"]) out.push(n.attributes["data-note-id"]); (n?.childNodes ?? []).forEach(walk) }
  walk(el)
  return out
}

/** Haven /feed holding `count` notes, answering with all of them whatever limit it was asked for. */
function vaultWith(count) {
  const evs = Array.from({ length: count }, (_, i) => ({ id: hex(0xabc000 + i), pubkey: me, kind: 1, created_at: now - i, tags: [], content: `note from ${i}`, sig: "" }))
  return { feed: { async event() { return { ok: true } }, async query(f) { return evs.filter(e => f.kinds.includes(e.kind) && (!f.until || e.created_at <= f.until)) } } }
}

function mount(count) {
  pool.ensureRelay = async () => ({})
  pool.querySync = async () => []
  pool.subscribeMany = () => ({ close() {}, params: { onevent() {} } })
  const el = document.createElement("div")
  const ctx = { vault: vaultWith(count), account: { follows: [me], relays: { read: [] }, loaded: true } }
  render(h(FeedScreen, { ctx }), el)
  return el
}

test("a feed far past the ceiling puts a window's worth of notes in the DOM, not a thousand", async () => {
  const el = mount(1000)
  await until(() => rows(el).length > 0, "the first draw")
  await tick(80)
  const drawn = rows(el)
  assert.equal(drawn.length, DRAW_NOTES, `${drawn.length} rows drawn of 1,000 notes`)
  assert.equal(drawn[0], hex(0xabc000), "the newest note is the top row")
  assert.equal(drawn.at(-1), hex(0xabc000 + DRAW_NOTES - 1), "and the window is the top of the list, in order")
  assert.ok(DRAW_NOTES < MAX_NOTES, "the window is smaller than what is kept in memory")
  render(null, el)
})

test("a feed shorter than the window draws all of it", async () => {
  const el = mount(40)
  await until(() => rows(el).length > 0, "the first draw")
  await tick(80)
  assert.equal(rows(el).length, 40)
  render(null, el)
})
