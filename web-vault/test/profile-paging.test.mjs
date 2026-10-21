// A profile's tabs paging back as the iPhone's ProfileFeedLoader does (src/screens/ProfileTabs.jsx useNoteStream): two
// quiet pages end a stream, an empty tab pages back by itself up to 8 times and then offers "Look further back", and
// the wording is the iPhone's. Renders through Vite's SSR loader (for the JSX) into a small fake DOM; throwaway keys.
import test from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { generateSecretKey, finalizeEvent } from "nostr-tools/pure"

// Just enough DOM for preact to render into and for the test to read text back (as wallet-refresh.test.mjs).
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.listeners = {} }
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
  addEventListener(type, fn) { this.listeners[type] = fn }
  removeEventListener(type) { delete this.listeners[type] }
  get textContent() { return this.nodeType === 3 ? this.data : this.childNodes.map(c => c.textContent).join("") }
  set textContent(v) { this.childNodes = []; if (v) this.appendChild(document.createTextNode(v)) }
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach(c => all(c, out)); return out }
const buttons = el => all(el).filter(n => n.localName === "button")
// Preact names the listener "Click" here (no onclick on this fake node) and finds the handler by the event's type.
const click = b => b.listeners.Click.call(b, { type: "Click", currentTarget: b, target: b, preventDefault() {}, stopPropagation() {} })

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
const { ProfileTabs, useNoteStream } = await vite.ssrLoadModule("/src/screens/ProfileTabs.jsx")
test.after(() => vite.close())

const tick = (ms = 0) => new Promise(r => setTimeout(r, ms))
const until = async (cond, what) => { for (let i = 0; i < 400; i++) { if (cond()) return; await tick(5) } assert.fail(`timed out waiting for ${what}`) }
const sk = generateSecretKey()
const ID = "a".repeat(64)
let t = 10_000
const reply = () => finalizeEvent({ kind: 1, created_at: --t, tags: [["e", ID]], content: "a reply" }, sk)

// `older(until)` -> a page; the tabs' streams come from useNoteStream as the screens' do.
function Profile({ open, older, tagged = { open: async () => [], older: async () => [] }, articles = [], out }) {
  const notes = useNoteStream(open, older, [])
  const tags = useNoteStream(tagged.open, tagged.older, [])
  out.notes = notes
  return h(ProfileTabs, { notes, tagged: tags, articles, pubkey: "b".repeat(64), blocked: new Set() })
}

test("the tab bar is the iPhone's order, Articles only when there are some", async () => {
  const el = document.createElement("div"), out = {}
  render(h(Profile, { open: async () => [], older: async () => [], out }), el)
  assert.deepEqual(buttons(el).map(b => b.textContent), ["Notes", "Media", "Replies", "Reposts", "Tagged"])
  const art = finalizeEvent({ kind: 30023, created_at: 1, tags: [["d", "x"], ["title", "T"]], content: "" }, sk)
  render(h(Profile, { open: async () => [], older: async () => [], articles: [art], out }), el)
  assert.deepEqual(buttons(el).map(b => b.textContent).slice(0, 6), ["Notes", "Media", "Replies", "Reposts", "Tagged", "Articles"])
  render(null, el)
})

test("an empty Notes tab pages back 8 times by itself, then says so and offers Look further back", async () => {
  const el = document.createElement("div"), out = {}
  let pages = 0
  // Every page holds only replies: the pile grows, the Notes tab stays empty.
  render(h(Profile, { open: async () => [reply()], older: async () => { pages++; return [reply()] }, out }), el)
  const further = () => buttons(el).find(b => b.textContent === "Look further back")
  // Effects run after a frame's timeout here (tens of ms a page): wait until no page has come for 300 ms.
  for (let seen = -1; seen !== pages;) { seen = pages; await tick(300) }
  assert.equal(pages, 8, "8 by itself, no more")
  assert.ok(further())
  assert.match(el.textContent, /None in the latest posts/)
  click(further())
  await until(() => pages === 9 && !out.notes.paging, "the page asked for")
  render(null, el)
})

test("two quiet pages in a row end a stream: the empty tab then reads No notes yet, with nothing to look back for", async () => {
  const el = document.createElement("div"), out = {}
  let pages = 0
  render(h(Profile, { open: async () => [reply()], older: async () => { pages++; return [] }, out }), el)
  await until(() => !out.notes.hasMore, "the end of the stream")
  await tick(20)
  assert.equal(pages, 2)
  assert.match(el.textContent, /No notes yet/)
  assert.ok(!buttons(el).some(b => b.textContent === "Look further back"))
  render(null, el)
})

test("while the opening load runs an empty tab says Loading…", async () => {
  const el = document.createElement("div"), out = {}
  let finish
  render(h(Profile, { open: () => new Promise(r => { finish = r }), older: async () => [], out }), el)
  await until(() => finish, "the opening load to start")
  assert.match(el.textContent, /Loading…/)
  finish([])
  await until(() => !out.notes.opening, "the opening load")
  await tick(10)
  assert.match(el.textContent, /No notes yet/)
  render(null, el)
})
