// The Following feed's first sync: notes show as each chunk of follows lands, not only after the last one, and the
// screen never says "Up to date" before the follow list is known. Renders FeedScreen (through Vite's SSR loader, for
// the JSX) into a small fake DOM, with a fake vault and fake relays.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"

// Just enough DOM for preact to render into and for the test to read text back.
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) {
    n.parentNode?.removeChild(n)
    const i = ref ? this.childNodes.indexOf(ref) : -1
    i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n)
    n.parentNode = this
    return n
  }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener() {}
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
const { pool } = await vite.ssrLoadModule("/src/net/pool.js")
test.after(() => vite.close())

Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const hex = (n, w = 64) => n.toString(16).padStart(w, "0")
const follows = Array.from({ length: 695 }, (_, i) => hex(i + 1))
const now = Math.floor(Date.now() / 1000)

/** Haven /feed in memory. */
function fakeVault() {
  const evs = []
  const feed = {
    async event(ev) { if (evs.some(e => e.id === ev.id)) return { ok: false, message: "duplicate:" }; evs.push(ev); return { ok: true } },
    async query(f) {
      return evs.filter(e => f.kinds.includes(e.kind) && f.authors.includes(e.pubkey) && (!f.until || e.created_at <= f.until))
        .sort((a, b) => b.created_at - a.created_at).slice(0, f.limit)
    },
  }
  return { feed, outbox: feed }
}

/** Relays that answer each chunk of authors only when the test lets them. */
function gatedRelays() {
  const gates = []
  pool.ensureRelay = async () => ({})
  pool.querySync = async (_, f) => !f.kinds.includes(1) ? [] : new Promise(resolve => gates.push(() => resolve(f.authors.slice(0, 3).map((pk, i) => ({ id: hex(parseInt(pk, 16) * 10 + i), pubkey: pk, kind: 1, created_at: now - i, tags: [], content: `note from ${pk.slice(-3)}`, sig: "" })))))
  // Each relay is asked on its own: a chunk is one gate per relay (two here, the default relays).
  return { pending: () => gates.length, release: () => gates.shift()(), releaseChunk: () => { for (const g of gates.splice(0)) g() } }
}

function mount(account) {
  const el = document.createElement("div")
  const ctx = { vault: fakeVault(), account }
  render(h(FeedScreen, { ctx }), el)
  return { el, ctx, rerender: account => { ctx.account = account; render(h(FeedScreen, { ctx: { ...ctx, account } }), el) } }
}
const text = el => el.textContent
const until = async (cond, what) => { for (let i = 0; i < 200; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }

test("before the follow list arrives the feed doesn't claim to be up to date", async () => {
  gatedRelays()
  const { el } = mount({ follows: [], relays: { read: [] }, loaded: false })
  await tick(50)
  assert.match(text(el), /Loading your follows…/)
  assert.doesNotMatch(text(el), /Up to date/)
  render(null, el)
})

test("notes from the first chunk of follows show while later chunks are still syncing", async () => {
  const relays = gatedRelays()
  const m = mount({ follows: [], relays: { read: [] }, loaded: false })
  await tick(20)
  m.rerender({ follows, relays: { read: [] }, loaded: true })
  await until(() => relays.pending() > 0, "the first chunk's query")
  assert.match(text(m.el), /Fetching notes from the people you follow…/)
  assert.doesNotMatch(text(m.el), /No notes saved yet\./)

  relays.releaseChunk() // chunk 1 of 3 (follows 1-250) lands
  await until(() => relays.pending() > 0, "the second chunk's query")
  await until(() => /note from/.test(text(m.el)), "chunk 1's notes on screen")
  assert.match(text(m.el), /Syncing 250\/695 follows · 3 saved/)
  assert.doesNotMatch(text(m.el), /No notes saved yet\./)

  relays.releaseChunk()
  await until(() => relays.pending() > 0, "the third chunk's query")
  relays.releaseChunk()
  await until(() => /9 notes saved to your relay/.test(text(m.el)), "the finished sync")
  assert.equal((text(m.el).match(/note from/g) ?? []).length, 9, "a note both relays sent is saved once")
  render(null, m.el)
})

test("the first relay's notes show while a slower relay is still answering", async () => {
  const relays = gatedRelays()
  const m = mount({ follows: [], relays: { read: [] }, loaded: false })
  await tick(20)
  m.rerender({ follows, relays: { read: [] }, loaded: true })
  await until(() => relays.pending() === 2, "both relays asked for chunk 1")
  relays.release() // the fast relay answers; the slow one hasn't
  await until(() => /note from/.test(text(m.el)), "the fast relay's notes on screen")
  assert.equal(relays.pending(), 1, "the slow relay is still being waited on")
  assert.match(text(m.el), /Syncing 0\/695 follows · 3 saved/)
  relays.release()
  await until(() => relays.pending() > 0, "the second chunk's query")
  assert.equal((text(m.el).match(/note from/g) ?? []).length, 3, "the slow relay's copies aren't saved twice")
  for (let k = 0; k < 2; k++) { relays.releaseChunk(); await tick(20) }
  await until(() => /notes saved to your relay/.test(text(m.el)), "the finished sync")
  render(null, m.el)
})

test("two syncs at once (Refresh during the background tick) don't fail on a note both are writing", async () => {
  const { syncFeed } = await vite.ssrLoadModule("/src/net/sync.js")
  pool.ensureRelay = async () => ({})
  const evs = Array.from({ length: 150 }, (_, i) => ({ id: hex(i + 1), pubkey: follows[0], kind: 1, created_at: now - i, tags: [], content: "", sig: "" }))
  pool.querySync = async () => evs
  // Haven's client: one request per id at a time, answered on a later tick.
  const busy = new Set(), saved = new Set()
  const feed = {
    event: ev => busy.has(ev.id) ? Promise.reject(new Error(`request ${ev.id} already in flight`))
      : (busy.add(ev.id), tick(1).then(() => { busy.delete(ev.id); const ok = !saved.has(ev.id); saved.add(ev.id); return { ok, message: ok ? "" : "duplicate:" } })),
    query: async () => [],
  }
  const vault = { feed }
  const [a, b] = await Promise.all([syncFeed(vault, follows.slice(0, 3), ["wss://a", "wss://b"]), syncFeed(vault, follows.slice(0, 3), ["wss://a", "wss://b"])])
  assert.equal(a + b, 150, "every note saved once, neither sync failed")
})
