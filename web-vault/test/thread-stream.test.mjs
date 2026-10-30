// A thread opens as its replies arrive: each relay is asked on its own, a step moves on SETTLE_MS after the first relay
// answers instead of waiting for one that never does, every reply is stored and drawn as it lands, and a long thread
// is drawn a chunk at a time. Test keys only; no real relay is reached (pool.subscribeEose and querySync are stubbed).
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"
import { h, render } from "preact"
import { streamQuery, syncThread } from "../src/net/thread.js"
import { pool } from "../src/net/pool.js"

registerHooks({
  load(url, context, next) {
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { ThreadScreen } = await import("../src/screens/ThreadScreen.jsx")

const now = Math.floor(Date.now() / 1000)
const author = generateSecretKey(), replier = generateSecretKey()
const root = finalizeEvent({ kind: 1, created_at: now - 600, tags: [], content: "the root note" }, author)
const replyTo = (parent, i) => finalizeEvent({ kind: 1, created_at: now - 500 + i, tags: [["e", root.id, "", "root"], ["e", parent.id, "", "reply"]], content: `reply ${i}` }, replier)
const matches = (f, e) => (!f.ids || f.ids.includes(e.id)) && (!f.kinds || f.kinds.includes(e.kind)) &&
  (!f["#e"] || e.tags.some(t => t[0] === "e" && f["#e"].includes(t[1]))) && (!f.authors || f.authors.includes(e.pubkey))
const feedOf = events => ({
  query: async f => events.filter(e => matches(f, e)),
  event: async ev => { if (!events.some(e => e.id === ev.id)) events.push(ev); return { ok: true } },
})
const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what, ms = 2000) => { const end = Date.now() + ms; while (!cond()) { if (Date.now() > end) assert.fail(`timed out waiting for ${what}`); await tick(5) } }

// Relays the test scripts: "fast" answers what it holds at once, then EOSE; "stuck" never sends EOSE, and only sends
// what `late` holds once the test calls release(). Each subscription is one relay, as streamQuery opens them.
function stubRelays(t, { fast = [], late = [] }) {
  const stuck = []
  let released = false
  const subscribeEose = pool.subscribeEose, querySync = pool.querySync
  pool.subscribeEose = ([url], f, p) => {
    let open = true
    const close = reason => { if (open) { open = false; p.onclose?.([reason]) } }
    if (url.includes("fast")) queueMicrotask(() => { for (const e of fast) if (open && matches(f, e)) p.onevent(e); close("closed automatically on eose") })
    else {
      const answer = () => { for (const e of late) if (open && matches(f, e)) p.onevent(e); close("closed automatically on eose") }
      released ? queueMicrotask(answer) : stuck.push(answer)
    }
    return { close: () => close("closed by caller") }
  }
  pool.querySync = async () => []
  t.after(() => { pool.subscribeEose = subscribeEose; pool.querySync = querySync })
  // From release() on, the stuck relay answers: what it held back, and any later ask at once.
  return { release: () => { released = true; stuck.splice(0).forEach(go => go()) } }
}
const RELAYS = ["wss://fast.example", "wss://stuck.example"]

test("streamQuery settles SETTLE_MS after the first answer, and still hands over what a slower relay sends later", async t => {
  const a = replyTo(root, 1), b = replyTo(root, 2)
  const relays = stubRelays(t, { fast: [a], late: [b] })
  const got = []
  const q = streamQuery(RELAYS, { kinds: [1], "#e": [root.id] }, { settle: 30, onevent: e => got.push(e.id) })
  let doneYet = false
  q.done.then(() => { doneYet = true })
  const t0 = Date.now()
  const settled = await q.settled
  assert.ok(Date.now() - t0 < 500, "settled without waiting for the stuck relay")
  assert.deepEqual(settled.map(e => e.id), [a.id])
  assert.equal(doneYet, false, "done waits for the stuck relay")
  relays.release()
  await q.done
  assert.deepEqual(got, [a.id, b.id])
})

test("streamQuery settles as soon as `enough` holds, and close() ends `done`", async t => {
  stubRelays(t, { fast: [root] })
  const q = streamQuery(RELAYS, { ids: [root.id] }, { settle: 5000, enough: evs => evs.some(e => e.id === root.id) })
  assert.equal((await q.settled)[0].id, root.id)
  q.close()
  await q.done
})

test("close() closes only the relays still open, never one that already ended on EOSE", async t => {
  const subscribeEose = pool.subscribeEose
  t.after(() => { pool.subscribeEose = subscribeEose })
  const closedByUs = []
  pool.subscribeEose = ([url], f, p) => {
    if (url.includes("fast")) queueMicrotask(() => { p.onevent(root); p.onclose?.(["closed automatically on eose"]) })
    return { close: () => { closedByUs.push(url); p.onclose?.(["closed by caller"]) } }
  }
  const q = streamQuery(RELAYS, { ids: [root.id] }, { enough: evs => evs.length > 0 })
  await q.settled
  await tick()
  q.close()
  q.close()
  await q.done
  assert.deepEqual(closedByUs, ["wss://stuck.example"])
})

test("a relay that fails (not EOSE) doesn't start the settle clock", async t => {
  const a = replyTo(root, 1)
  const subscribeEose = pool.subscribeEose
  t.after(() => { pool.subscribeEose = subscribeEose })
  let answer
  pool.subscribeEose = ([url], f, p) => {
    if (url.includes("dead")) queueMicrotask(() => p.onclose?.(["connection failed"]))
    else answer = () => { p.onevent(a); p.onclose?.(["closed automatically on eose"]) }
    return { close() {} }
  }
  const q = streamQuery(["wss://dead.example", "wss://slow.example"], { kinds: [1] }, { settle: 5 })
  let settled = false
  q.settled.then(() => { settled = true })
  await tick(40)
  assert.equal(settled, false, "still waiting for the relay that is up")
  answer()
  assert.deepEqual((await q.settled).map(e => e.id), [a.id])
})

test("syncThread stores replies as they land and resolves without the stuck relay; its late replies follow", async t => {
  const r1 = replyTo(root, 1), r2 = replyTo(r1, 2), late = replyTo(root, 3)
  const relays = stubRelays(t, { fast: [root, r1, r2], late: [late] })
  const store = []
  const vault = { feed: feedOf(store) }
  let roots = 0, progress = 0
  const t0 = Date.now()
  const synced = await syncThread(vault, r1.id, RELAYS, { settle: 20, onRoot: rid => { roots++; assert.equal(rid, root.id) }, onProgress: () => progress++ })
  assert.ok(Date.now() - t0 < 1000, "resolved without the stuck relay")
  assert.equal(synced.rootId, root.id)
  assert.equal(roots, 1)
  assert.deepEqual(new Set(store.map(e => e.id)), new Set([root.id, r1.id, r2.id]))
  assert.ok(progress >= 1, "the screen was told as they were stored")
  relays.release()
  await synced.done
  assert.ok(store.some(e => e.id === late.id), "the late relay's reply is stored too")
  assert.equal(synced.stored, 4)
})

// Just enough DOM for preact to render ThreadScreen into and for the test to count notes back.
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
const replyRows = el => (el.textContent.match(/reply \d+/g) ?? []).length

test("the screen draws the stored thread at once, then the relays' replies as they land, before the stuck relay ends", async t => {
  Object.defineProperty(globalThis.navigator, "onLine", { value: true, configurable: true })
  const fresh = Array.from({ length: 5 }, (_, i) => replyTo(root, i))
  stubRelays(t, { fast: fresh })
  const ctx = { vault: { feed: feedOf([root]) }, account: { relays: { read: ["wss://fast.example", "wss://stuck.example"] } } }
  const el = document.createElement("div")
  render(h(ThreadScreen, { ctx, id: root.id }), el)
  await until(() => /the root note/.test(el.textContent), "the stored root")
  await until(() => replyRows(el) === 5, "the fast relay's replies")
  render(null, el)
})

test("a long thread is drawn a chunk at a time, and a reply opened deep in it is drawn at once", async t => {
  Object.defineProperty(globalThis.navigator, "onLine", { value: false, configurable: true })
  stubRelays(t, {})
  const replies = Array.from({ length: 120 }, (_, i) => replyTo(root, i))
  const ctx = { vault: { feed: feedOf([root, ...replies]) }, account: { relays: { read: [] } } }
  const el = document.createElement("div")
  render(h(ThreadScreen, { ctx, id: root.id }), el)
  await until(() => replyRows(el) > 0, "the first replies")
  assert.ok(replyRows(el) < 120, `first frame draws a chunk, not all (${replyRows(el)})`)
  await until(() => replyRows(el) === 120, "every reply, a chunk per frame")
  render(null, el)

  const deep = replies[100]
  render(h(ThreadScreen, { ctx, id: deep.id }), el)
  await until(() => replyRows(el) > 0, "the deep reply's thread")
  assert.match(el.textContent, /reply 100/)
  render(null, el)
})
