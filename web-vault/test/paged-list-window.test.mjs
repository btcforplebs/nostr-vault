// Logen's slow Vault pictures (2026-11-04): new posts going in above the rows drawn must not push the bottom rows off
// the page, or the photos loading in them are cancelled and start again from zero. Renders PagedList in a small fake
// DOM (through Vite's SSR loader for the JSX) and counts rows mounted and unmounted.
import test, { after } from "node:test"
import assert from "node:assert/strict"
import { fileURLToPath } from "node:url"
import { createServer } from "vite"
import { h, render } from "preact"
import { useEffect } from "preact/hooks"
import { act } from "preact/test-utils"

class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {}; this.listeners = {} }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const s = this.parentNode?.childNodes; return s ? s[s.indexOf(this) + 1] ?? null : null }
  insertBefore(n, ref) { n.parentNode?.removeChild(n); const i = ref ? this.childNodes.indexOf(ref) : -1; i < 0 ? this.childNodes.push(n) : this.childNodes.splice(i, 0, n); n.parentNode = this; return n }
  appendChild(n) { return this.insertBefore(n, null) }
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = String(v) }
  removeAttribute(k) { delete this.attributes[k] }
  addEventListener() {}
  removeEventListener() {}
}
globalThis.document = {
  createElement: name => new Node(1, name),
  createElementNS: (_, name) => new Node(1, name),
  createTextNode: data => Object.assign(new Node(3, "#text"), { data: String(data) }),
}

const root = fileURLToPath(new URL("..", import.meta.url))
const vite = await createServer({ root, configFile: false, logLevel: "silent", appType: "custom", server: { middlewareMode: true, hmr: false, ws: false }, oxc: { jsx: { runtime: "automatic", importSource: "preact" } } })
after(() => vite.close())
const { PagedList } = await vite.ssrLoadModule("/src/components/PagedList.jsx")

test("five new posts on top keep all 100 rows below drawn: no row unmounts, so no photo read is cancelled", async () => {
  const mounted = new Set(), unmounted = []
  // A row as the Vault draws one: its photo starts loading when it mounts and stops when it unmounts (MediaImage).
  const Row = ({ id }) => { useEffect(() => { mounted.add(id); return () => { mounted.delete(id); unmounted.push(id) } }, []); return h("article", null, id) }
  const draw = it => h(Row, { key: it.id, id: it.id })
  const rows = (from, to) => Array.from({ length: to - from + 1 }, (_, i) => ({ id: `r${to - i}` }))
  const host = new Node(1, "div")
  let items = rows(1, 300)
  await act(() => render(h(PagedList, { items, render: draw, shown: 100, onMore() {} }), host))
  assert.equal(mounted.size, 100)
  items = [...rows(301, 305), ...items]
  await act(() => render(h(PagedList, { items, render: draw, shown: 100, onMore() {} }), host))
  assert.deepEqual(unmounted, [], "no row left the page")
  assert.equal(mounted.size, 105, "the new rows are drawn on top of the 100")
  // Another list (a mode switch) starts again at the caller's 100.
  await act(() => render(h(PagedList, { items: rows(1000, 1200), render: draw, shown: 100, onMore() {} }), host))
  assert.equal(mounted.size, 100)
  await act(() => render(null, host))
})
