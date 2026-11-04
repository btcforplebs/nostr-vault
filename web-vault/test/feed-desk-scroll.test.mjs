// The Feed on the desktop layout scrolls in its own pane (desktop.css .desk-list), not the window (Logen, 2026-11-03):
// FeedExtras feedScroller/scrollTopOf/scrollToTop pick the pane there and the window on the phone. Small fake DOM, through Vite's SSR loader for the JSX.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { act } from "preact/test-utils"

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
  addEventListener(type, fn) { (this.listeners[type] ??= new Set()).add(fn) }
  removeEventListener(type, fn) { this.listeners[type]?.delete(fn) }
  fire(type) { for (const fn of this.listeners[type] ?? []) fn() }
  get classes() { return String(this.className ?? this.attributes.class ?? "").split(/\s+/) }
  closest(sel) { for (let n = this; n; n = n.parentNode) if (n.classes && sel.startsWith(".") && n.classes.includes(sel.slice(1))) return n; return null }
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
after(() => vite.close())
const { feedScroller, scrollTopOf, scrollToTop } = await vite.ssrLoadModule("/src/components/FeedExtras.jsx")

const pane = () => { const p = new Node(1, "div"); p.className = "desk-list"; p.scrollTop = 0; p.calls = []; p.scrollTo = o => p.calls.push(o); return p }

test("feedScroller: the desktop pane around the list; null (the window) on the phone", () => {
  const p = pane(), inner = new Node(1, "main"), loose = new Node(1, "main")
  p.appendChild(new Node(1, "div")).appendChild(inner)
  assert.equal(feedScroller(inner), p)
  assert.equal(feedScroller(loose), null)
  assert.equal(feedScroller(null), null)
})

test("scrollTopOf and scrollToTop use the pane when there is one, else the window", () => {
  const p = pane()
  p.scrollTop = 1617
  globalThis.scrollY = 0 // the desktop's window never scrolls
  assert.equal(scrollTopOf(p), 1617, "not the window's 0: auto-load must not insert while you read")
  scrollToTop(p)
  assert.deepEqual(p.calls, [{ top: 0, behavior: "smooth" }])
  const win = []
  globalThis.scrollTo = o => win.push(o)
  globalThis.scrollY = 300
  assert.equal(scrollTopOf(null), 300)
  scrollToTop(null)
  assert.deepEqual(win, [{ top: 0, behavior: "smooth" }])
})
