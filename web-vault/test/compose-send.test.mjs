// The web composer against the iPhone's: the send countdown + Undo (PendingPostManager / PostActionPill: the same
// 0/5/10 s, default 5, the same wording; Undo leaves nothing signed or sent), Cancel's "Save this note as a draft?",
// and the compact "Replying to" strip. The real ComposeScreen is rendered with a
// counting signer and a stubbed pool; the clock is node's mock timers. Throwaway keys only: nothing is published.
import test, { mock } from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils" // Vite 8's own transformer
import { h, render } from "preact"
import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure"
import { SEND_DELAY_KEY, countdownText, sendAction, sendDelaySeconds, startCountdown, setSendDelaySeconds, sendDelayNote } from "../src/net/send-delay.js"
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

const store = m => ({ getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: k => m.delete(k) })

test("the delay is the iPhone's: 5 s by default, 0/5/10 from the same key, anything else the default", () => {
  const m = new Map()
  assert.equal(sendDelaySeconds(store(m)), 5)
  for (const [v, want] of [["0", 0], ["10", 10], ["5", 5], ["7", 5], ["", 5], ["x", 5]]) { m.set(SEND_DELAY_KEY, v); assert.equal(sendDelaySeconds(store(m)), want) }
  assert.equal(sendDelaySeconds(undefined), 5)
})

test("Settings › Send Delay writes the key the composer reads, only one of its choices, with the iPhone's footer", () => {
  const m = new Map()
  for (const s of [0, 10, 5]) { setSendDelaySeconds(s, store(m)); assert.equal(sendDelaySeconds(store(m)), s) }
  setSendDelaySeconds(0, store(m))
  setSendDelaySeconds(7, store(m))
  assert.equal(m.get(SEND_DELAY_KEY), "0", "not a choice: nothing written")
  assert.equal(sendDelayNote(0), "Posts go out as soon as you tap. There's no undo.")
  assert.equal(sendDelayNote(10), "Posts wait 10 seconds before going out, so you can undo or edit them.")
})

test("the pill's words: 'Posting in 5s', whole seconds rounded up, never 0s", () => {
  assert.equal(countdownText("newPost", 5), "Posting in 5s")
  assert.equal(countdownText("reply", 4.2), "Replying in 5s")
  assert.equal(countdownText("quote", 0.05), "Quoting in 1s")
  assert.deepEqual([null, { mode: "reply" }, { mode: "quote" }].map(sendAction), ["newPost", "reply", "quote"])
})

// A clock the test moves by hand.
function fakeClock() {
  let t = 0, fn = null
  return { now: () => t, every: f => { fn = f; return 1 }, stop: () => { fn = null }, advance: ms => { for (let i = 0; i < ms / 100; i++) { t += 100; fn?.() } }, running: () => !!fn }
}

test("the countdown ticks down, then runs onDone once; cancel before the end and onDone never runs", () => {
  const c = fakeClock(), ticks = []
  let done = 0
  startCountdown({ seconds: 5, onTick: r => ticks.push(r), onDone: () => done++, clock: c })
  c.advance(4900)
  assert.equal(done, 0)
  assert.ok(ticks.at(-1) > 0 && ticks.at(-1) <= 0.1 + 1e-9)
  c.advance(500)
  assert.equal(done, 1)
  assert.equal(c.running(), false)

  const c2 = fakeClock()
  let done2 = 0
  const h2 = startCountdown({ seconds: 5, onDone: () => done2++, clock: c2 })
  c2.advance(3000)
  assert.equal(h2.cancel(), true)
  c2.advance(10000)
  assert.equal(done2, 0)
  assert.equal(h2.cancel(), false, "a second cancel stops nothing")
})

test("Off (0 s) sends straight away, with nothing to cancel", () => {
  let done = 0
  const h = startCountdown({ seconds: 0, onDone: () => done++, clock: fakeClock() })
  assert.equal(done, 1)
  assert.equal(h.cancel(), false)
})

// ---- the real composer ----
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.on = {}
    // Properties, so preact sets them as properties (as on a real textarea) instead of attributes.
    if (localName === "textarea") { this.value = ""; this.readOnly = false }
  }
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
  addEventListener(type, fn) { this.on[type.toLowerCase()] = { type, fn } }
  removeEventListener(type) { delete this.on[type.toLowerCase()] }
  fire(name, extra = {}) { const { type, fn } = this.on[name]; fn.call(this, { type, currentTarget: this, target: this, stopPropagation() {}, preventDefault() {}, ...extra }) }
  click() { this.fire("click") }
  focus() { focusedNode = this }
  setSelectionRange() {}
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  all(pred) { return [...(pred(this) ? [this] : []), ...this.childNodes.flatMap(c => c.all?.(pred) ?? [])] }
}
let focusedNode = null
globalThis.document = {
  body: new Node(1, "body"),
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
globalThis.location = { hash: "#/compose", hostname: "nostrvault.app" }
let backs = 0
globalThis.history = { state: null, back: () => { backs++ } }
const local = new Map()
globalThis.localStorage = store(local)
// An in-memory IndexedDB, just what idbDrafts asks of it.
const dbs = new Map()
globalThis.indexedDB = {
  open: name => {
    const req = {}
    setTimeout(() => {
      const data = dbs.get(name) ?? new Map(); dbs.set(name, data)
      const db = { close() {}, transaction: () => {
        const tx = {}
        const s = { get: k => ({ result: data.get(k) }), put: (v, k) => { data.set(k, v); return {} }, delete: k => { data.delete(k); return {} } }
        tx.objectStore = () => s
        setTimeout(() => tx.oncomplete?.())
        return tx
      } }
      req.result = db; req.onsuccess?.()
    })
    return req
  },
}
const { ComposeScreen, replySnippet, reachedRelay } = await import("../src/screens/ComposeScreen.jsx")
// Preact runs effects after a paint timer (~35 ms without requestAnimationFrame); setTimeout isn't mocked.
const flush = async () => { for (let i = 0; i < 3; i++) { await new Promise(r => setTimeout(r, 50)); await new Promise(r => setImmediate(r)) } }

let relayAnswer = () => Promise.resolve("ok")
async function composer(props = {}) {
  const sk = generateSecretKey(), pubkey = getPublicKey(sk)
  const signed = [], stored = [], published = []
  const ctx = {
    session: { pubkey },
    signer: { method: "nip07", signEvent: async t => { const e = finalizeEvent(t, sk); signed.push(e); return e } },
    vault: { outbox: { event: async e => { stored.push(e); return { ok: true } } }, feed: {} },
    account: { relays: { write: ["wss://relay.example"] } },
  }
  pool.publish = (urls, e) => { published.push({ urls, e }); return urls.map(() => relayAnswer()) }
  const root = new Node(1, "div")
  render(h(ComposeScreen, { ctx, ...props }), root)
  await flush()
  const box = root.all(n => n.localName === "textarea")[0]
  const type = async t => { box.value = t; box.fire("input"); await flush() }
  const button = label => root.all(n => n.localName === "button" && n.textContent === label)[0]
  return { root, signed, stored, published, type, button, text: () => root.textContent, box, unmount: () => render(null, root) }
}

test("Post waits 5 s with 'Posting in 5s' and Undo; nothing is signed or sent until it ends, then once", async t => {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => mock.timers.reset())
  local.clear()
  const c = await composer()
  await c.type("ted send-delay probe")
  c.button("Post").click(); await flush()
  assert.match(c.text(), /Posting in 5s/)
  assert.ok(c.button("Undo"))
  assert.equal(c.box.readOnly, true, "the note can't change under the countdown")
  mock.timers.tick(2600); await flush()
  assert.match(c.text(), /Posting in 3s/)
  mock.timers.tick(2300); await flush()
  assert.equal(c.signed.length, 0, "nothing signed during the countdown")
  assert.equal(c.published.length, 0)
  mock.timers.tick(200); await flush()
  assert.equal(c.signed.length, 1)
  assert.equal(c.signed[0].content, "ted send-delay probe")
  assert.equal(c.stored.length, 1)
  assert.equal(c.published.length, 1)
  assert.doesNotMatch(c.text(), /Posting in/)
  assert.equal(c.button("Undo"), undefined)
  c.unmount()
})

test("Undo: nothing signed, nothing sent, the note stays in the box, and it says so", async t => {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => mock.timers.reset())
  local.clear()
  const c = await composer()
  await c.type("ted undo probe")
  c.button("Post").click(); await flush()
  mock.timers.tick(3000); await flush()
  c.button("Undo").click(); await flush()
  mock.timers.tick(20000); await flush()
  assert.equal(c.signed.length, 0)
  assert.equal(c.published.length, 0)
  assert.equal(c.stored.length, 0)
  assert.equal(c.box.value, "ted undo probe")
  assert.equal(c.box.readOnly, false)
  assert.match(c.text(), /Not sent\. Nothing was signed/)
  c.unmount()
})

test("leaving the composer mid-countdown sends nothing", async t => {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => mock.timers.reset())
  local.clear()
  const c = await composer()
  await c.type("ted leave probe")
  c.button("Post").click(); await flush()
  c.unmount()
  mock.timers.tick(20000); await flush()
  assert.equal(c.signed.length, 0)
  assert.equal(c.published.length, 0)
})

test("Send Delay Off: posts at once with no pill; 10 s: 'Posting in 10s'", async t => {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => mock.timers.reset())
  local.clear(); local.set(SEND_DELAY_KEY, "0")
  const c = await composer()
  await c.type("ted off probe")
  c.button("Post").click(); await flush()
  assert.doesNotMatch(c.text(), /Posting in/)
  assert.equal(c.signed.length, 1)
  c.unmount()
  local.set(SEND_DELAY_KEY, "10")
  const d = await composer()
  await d.type("ted ten probe")
  d.button("Post").click(); await flush()
  assert.match(d.text(), /Posting in 10s/)
  d.button("Undo").click(); await flush()
  d.unmount()
})

test("Cancel on an empty box just closes; with a note it asks 'Save this note as a draft?'", async () => {
  local.clear(); backs = 0
  const c = await composer()
  c.button("Cancel").click(); await flush()
  assert.equal(backs, 1)
  assert.doesNotMatch(c.text(), /Save this note as a draft\?/)
  await c.type("ted cancel probe")
  c.button("Cancel").click(); await flush()
  assert.equal(backs, 1, "not closed yet: it asks first")
  assert.match(c.text(), /Save this note as a draft\?/)
  assert.ok(c.button("Save Draft") && c.button("Discard"))
  c.unmount()
})

test("Save Draft closes and keeps the draft; Discard deletes it and closes", async () => {
  local.clear(); backs = 0
  const c = await composer()
  await c.type("ted keep probe")
  c.button("Cancel").click(); await flush()
  c.button("Save Draft").click(); await flush()
  assert.equal(backs, 1)
  const drafts = [...dbs.values()].at(-1)
  assert.equal(drafts.get("new")?.text, "ted keep probe")
  c.unmount()

  const d = await composer()
  await d.type("ted discard probe")
  d.button("Cancel").click(); await flush()
  d.button("Discard").click(); await flush()
  assert.equal(backs, 2)
  assert.equal([...dbs.values()].at(-1).has("new"), false, "the draft is gone")
  assert.equal(d.box.value, "")
  d.unmount()
})

test("Cancel during the countdown stops it: nothing is signed or sent", async t => {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => mock.timers.reset())
  local.clear()
  const c = await composer()
  await c.type("ted cancel-countdown probe")
  c.button("Post").click(); await flush()
  c.button("Cancel").click(); await flush()
  mock.timers.tick(20000); await flush()
  assert.equal(c.signed.length, 0)
  assert.equal(c.published.length, 0)
  c.unmount()
})

test("the reply strip's text drops media links and nostr: references, on one line", () => {
  assert.equal(replySnippet("Look at this\nhttps://x.example/a.jpg\nnostr:nevent1abc and more"), "Look at this and more")
  assert.equal(replySnippet("https://x.example/a.jpg"), "")
})

// After a send, as the iPhone's sheet does: closed back to the page it came from, or Done when there's none.
async function sendOff(t, props) {
  mock.timers.enable({ apis: ["setInterval", "Date"] })
  t.after(() => { mock.timers.reset(); history.state = null; relayAnswer = () => Promise.resolve("ok") })
  local.clear(); local.set(SEND_DELAY_KEY, "0"); backs = 0
  const c = await composer(props)
  await c.type("tory close probe")
  c.button(props?.fixed ? "Reply" : "Post").click(); await flush()
  return c
}

test("a sent note closes the composer back to the page it was opened from", async t => {
  history.state = { nvDepth: 2 }
  const c = await sendOff(t)
  assert.equal(c.published.length, 1)
  assert.equal(backs, 1, "went back once")
  assert.equal(c.button("Done"), undefined)
  c.unmount()
})

test("opened as the first page: the note sends, nothing goes back, and Done shows", async t => {
  history.state = { nvDepth: 0 }
  const c = await sendOff(t)
  assert.equal(c.published.length, 1)
  assert.equal(backs, 0)
  assert.ok(c.button("Done"))
  assert.match(c.text(), /✓ Sent to \d+ of \d+ relays/)
  c.unmount()
})

test("a note no relay took stays open with its errors", async t => {
  history.state = { nvDepth: 2 }
  relayAnswer = () => Promise.reject(new Error("blocked: test"))
  const c = await sendOff(t)
  assert.equal(backs, 0)
  assert.equal(c.button("Done"), undefined)
  assert.match(c.text(), /No relay took it/)
  c.unmount()
})

test("only a relay other than this machine's own counts as sent", () => {
  assert.equal(reachedRelay({ relays: [{ url: "ws://127.0.0.1", local: true, ok: true }, { url: "wss://a", ok: false }] }), false)
  assert.equal(reachedRelay({ relays: [{ url: "wss://a", ok: true }] }), true)
  assert.equal(reachedRelay(null), false)
})

test("opened from Reply, the box has the focus at once; the reply box under a thread doesn't take it", async () => {
  local.clear(); focusedNode = null
  const c = await composer()
  assert.equal(focusedNode, c.box, "the cursor is in the box, so the phone's keyboard comes up")
  c.unmount()
  focusedNode = null
  const d = await composer({ inline: true })
  assert.notEqual(focusedNode, d.box)
  d.unmount()
})
