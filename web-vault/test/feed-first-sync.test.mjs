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
  addEventListener(type, fn) { (this.on ??= {})[type] = fn } // kept, so a test can click
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
const { pool, DEFAULT_RELAYS } = await vite.ssrLoadModule("/src/net/pool.js")
const R = DEFAULT_RELAYS.length // an account with no read list reads from the defaults
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
  // The live subscription for new notes (net/feed-live.js): recorded, never opened.
  const live = []
  pool.subscribeMany = (urls, filter, params) => { const sub = { filter, params, closed: false, close() { sub.closed = true } }; live.push(sub); return sub }
  // Each relay is asked on its own: a chunk is one gate per relay (R here, the default relays).
  return { live, pending: () => gates.length, release: () => gates.shift()(), releaseChunk: () => { for (const g of gates.splice(0)) g() } }
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

test("the first chunk of follows is asked alone and its notes show; the other chunks are then asked together", async () => {
  const relays = gatedRelays()
  const m = mount({ follows: [], relays: { read: [] }, loaded: false })
  await tick(20)
  m.rerender({ follows, relays: { read: [] }, loaded: true })
  await until(() => relays.pending() === R, "chunk 1 asked of every default relay")
  await tick(20)
  assert.equal(relays.pending(), R, "later chunks asked before the first screen's chunk landed")
  assert.match(text(m.el), /Fetching notes from the people you follow…/)
  assert.doesNotMatch(text(m.el), /No notes saved yet\./)

  relays.releaseChunk() // chunk 1 of 3 (follows 1-250) lands
  await until(() => /note from/.test(text(m.el)), "chunk 1's notes on screen")
  // 695 follows: chunks 2 and 3 open together, not one after the other.
  await until(() => relays.pending() === 2 * R, "chunks 2 and 3 asked together")
  assert.match(text(m.el), /Syncing 250\/695 follows · 3 saved/)
  assert.doesNotMatch(text(m.el), /No notes saved yet\./)

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
  await until(() => relays.pending() === R, "every default relay asked for chunk 1")
  relays.release() // the fast relay answers; the slow ones haven't
  await until(() => /note from/.test(text(m.el)), "the fast relay's notes on screen")
  assert.equal(relays.pending(), R - 1, "the slow relays are still being waited on")
  assert.match(text(m.el), /Syncing 0\/695 follows · 3 saved/)
  for (let i = 1; i < R; i++) relays.release()
  await until(() => relays.pending() > 0, "the next chunks' queries")
  assert.equal((text(m.el).match(/note from/g) ?? []).length, 3, "the slow relay's copies aren't saved twice")
  relays.releaseChunk()
  await until(() => /notes saved to your relay/.test(text(m.el)), "the finished sync")
  render(null, m.el)
})

test("answers landing while the feed is being read wait for one more read, not one read each", async () => {
  const relays = gatedRelays()
  // Its four relays and the defaults, each with notes of its own: every answer saves something.
  const gated = pool.querySync
  let n = 1000
  pool.querySync = async (urls, f, o) => (await gated(urls, f, o)).map(e => ({ ...e, id: hex(n++) }))
  const own = ["wss://c", "wss://d", "wss://e", "wss://f"]
  const m = mount({ follows: [], relays: { read: [] }, loaded: false })
  // A read of every follow takes a while in Haven; count the reads of more than one note.
  const query = m.ctx.vault.feed.query.bind(m.ctx.vault.feed)
  let reads = 0
  m.ctx.vault.feed.query = async f => { if (f.limit > 1) reads++; await tick(30); return query(f) }
  await tick(20)
  m.rerender({ follows, relays: { read: own }, loaded: true })
  const N = own.length + R
  await until(() => relays.pending() === N, "chunk 1 asked of every relay")
  relays.releaseChunk()
  await until(() => relays.pending() === 2 * N, "chunks 2 and 3 asked")
  await until(() => /Syncing 250\/695/.test(text(m.el)), "chunk 1 shown")
  await tick(100)
  const before = reads
  relays.releaseChunk() // 2N answers, each saving notes, all inside one read
  await until(() => new RegExp(`${9 * N} notes saved to your relay`).test(text(m.el)), "the finished sync")
  assert.ok(reads - before <= 3, `${reads - before} reads for ${2 * N} answers`)
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

test("a follow's new note arrives live, is saved and waits behind the pill; leaving the Feed closes the subscription", async () => {
  const relays = gatedRelays()
  const m = mount({ follows: [], relays: { read: [] }, loaded: false })
  await tick(20)
  m.rerender({ follows, relays: { read: [] }, loaded: true })
  // The pill listens for scrolls on the window, which this DOM doesn't have: just enough of one, for this test.
  const window = { addEventListener() {}, removeEventListener() {}, scrollY: 0 }
  Object.assign(globalThis, window)
  await until(() => relays.pending() === R, "chunk 1 asked")
  relays.releaseChunk()
  await until(() => relays.pending() === 2 * R, "chunks 2 and 3 asked")
  relays.releaseChunk()
  await until(() => /notes saved to your relay/.test(text(m.el)), "the finished sync")
  // One REQ per 250 follows, from now on, for the feed's kinds.
  const open = relays.live.filter(s => !s.closed)
  assert.deepEqual(open.map(s => s.filter.authors.length), [250, 250, 195])
  assert.ok(open.every(s => s.filter.kinds.includes(1) && s.filter.since >= now - 5))
  const fresh = { id: hex(9_999_999), pubkey: follows[300], kind: 1, created_at: now + 60, tags: [], content: "live from a follow", sig: "" }
  open[1].params.onevent(fresh)
  open[1].params.onevent(fresh) // a second relay's copy
  open[0].params.onevent({ ...fresh, id: hex(9_999_998), pubkey: hex(9_999) }) // not a follow: dropped
  for (let i = 0; i < 100 && !/1 New Post(?!s)/.test(text(m.el)); i++) await tick(50) // a batch waits LIVE_BATCH_MS
  assert.match(text(m.el), /1 New Post(?!s)/)
  assert.doesNotMatch(text(m.el), /live from a follow/, "held behind the pill, not drawn under the reader")
  render(null, m.el)
  for (const k of Object.keys(window)) delete globalThis[k]
  assert.ok(relays.live.every(s => s.closed), "every live REQ closed")
})

test("Hashtag's new notes arrive live and wait behind the pill; a tap shows them on top; nothing is saved", async () => {
  const tagNote = (id, at, content) => ({ id: hex(id), pubkey: hex(70_000 + id), kind: 1, created_at: at, tags: [["t", "bitcoin"]], content, sig: "" })
  pool.ensureRelay = async () => ({})
  pool.querySync = async (_, f) => (f["#t"]?.[0] === "bitcoin" ? [tagNote(1, now - 100, "an older tagged note")] : [])
  const live = []
  pool.subscribeMany = (urls, filter, params) => { const sub = { filter, params, closed: false, close() { sub.closed = true } }; live.push(sub); return sub }
  const store = new Map([["nv-feed", JSON.stringify({ mode: "hashtag", tag: "bitcoin" })]])
  const window = { addEventListener() {}, removeEventListener() {}, requestAnimationFrame() { return 0 }, cancelAnimationFrame() {}, scrollY: 0, scrollTo() {}, localStorage: { getItem: k => store.get(k) ?? null, setItem: (k, v) => store.set(k, v), removeItem: k => store.delete(k) } }
  Object.assign(globalThis, window)
  try {
    const m = mount({ follows, relays: { read: ["wss://r"] }, loaded: true })
    await until(() => /an older tagged note/.test(text(m.el)), "the first page")
    await until(() => live.some(s => !s.closed), "the live REQ")
    const sub = live.find(s => !s.closed)
    assert.deepEqual(sub.filter["#t"], ["bitcoin"])
    assert.ok(sub.filter.since >= now - 5 && !sub.filter.limit)
    sub.params.onevent(tagNote(2, now + 30, "a new tagged note"))
    sub.params.onevent({ ...tagNote(3, now + 31, "untagged"), tags: [] }) // a relay that ignored #t: dropped
    for (let i = 0; i < 100 && !/1 New Post(?!s)/.test(text(m.el)); i++) await tick(50)
    assert.match(text(m.el), /1 New Post(?!s)/)
    assert.doesNotMatch(text(m.el), /a new tagged note/)
    const find = (n, pred) => pred(n) ? n : n.childNodes?.map(c => find(c, pred)).find(Boolean)
    const pill = find(m.el, n => n.attributes?.class?.startsWith("new-posts"))
    const [type, onClick] = Object.entries(pill.on).find(([k]) => /^click$/i.test(k))
    onClick.call(pill, { type }) // preact keys the handler by the event name it registered
    await until(() => /a new tagged note/.test(text(m.el)), "the new note shown")
    assert.ok(text(m.el).indexOf("a new tagged note") < text(m.el).indexOf("an older tagged note"), "on top")
    assert.doesNotMatch(text(m.el), /New Post/)
    assert.deepEqual(await m.ctx.vault.feed.query({ kinds: [1], authors: [hex(70_002)], limit: 5 }), [], "a stranger's note is not saved")
    render(null, m.el)
    assert.ok(live.every(s => s.closed), "the live REQ closed")
  } finally { for (const k of Object.keys(window)) delete globalThis[k] }
})
