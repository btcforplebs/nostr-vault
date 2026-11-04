// The web app refreshes on its own like other Nostr clients (Logen 2026-11-04): no "N new" pill and no Refresh button
// anywhere, and screens look again through components/auto-look.js.
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync, readdirSync, statSync } from "node:fs"
import { join } from "node:path"
import { fileURLToPath } from "node:url"
import { h, render } from "preact"
import { act } from "preact/test-utils"
import { useAutoLook } from "../src/components/auto-look.js"

const SRC = fileURLToPath(new URL("../src", import.meta.url))
const files = dir => readdirSync(dir).flatMap(f => { const p = join(dir, f); return statSync(p).isDirectory() ? files(p) : /\.jsx?$/.test(f) ? [p] : [] })

// What a refresh control looks like in this code: a Refresh label or aria-label, the ↻ glyph, or the pill.
const CONTROL = /aria-label="Refresh|title="Refresh"|>\s*(↻\s*)?Refresh\s*<|>↻<|NewPostsPill|class="new-posts|"Refresh history"|"Refresh balance"|"Refresh messages"/

test("no Refresh button and no new-posts pill left in the web app", () => {
  const all = files(SRC)
  assert.ok(all.length > 200 && all.some(f => f.endsWith("FeedScreen.jsx")), `scanned ${all.length} files`)
  const hits = all.flatMap(f => readFileSync(f, "utf8").split("\n").map((l, i) => [f, i + 1, l]).filter(([, , l]) => CONTROL.test(l)))
  assert.deepEqual(hits.map(([f, n]) => `${f.slice(SRC.length + 1)}:${n}`), [])
})

test("the scan can fail: it catches each shape a refresh control took before", () => {
  for (const line of ['<button aria-label="Refresh" />', '<a title="Refresh">', "<button>Refresh</button>", "<button>↻ Refresh</button>", "<b>↻</b>",
    "<NewPostsPill count={n} />", '<button class="new-posts">', 'aria-label="Refresh history"'])
    assert.ok(CONTROL.test(line), line)
  assert.ok(!CONTROL.test("const refresh = () => load()"), "a function named refresh is fine")
})

// A tiny document and window for the hook: visibility, online, and timers it can be driven by.
function env() {
  const on = new Map(), docOn = new Map()
  const doc = { hidden: false, addEventListener: (t, f) => docOn.set(t, f), removeEventListener: t => docOn.delete(t) }
  const saved = { document: globalThis.document, addEventListener: globalThis.addEventListener, removeEventListener: globalThis.removeEventListener }
  Object.assign(globalThis, { document: doc, addEventListener: (t, f) => on.set(t, f), removeEventListener: t => on.delete(t) })
  return { doc, on, docOn, restore: () => Object.assign(globalThis, saved) }
}
class Node {
  constructor(nodeType, localName) { this.nodeType = nodeType; this.localName = localName; this.childNodes = []; this.parentNode = null; this.style = {}; this.attributes = {} }
  appendChild(c) { this.childNodes.push(c); c.parentNode = this; return c }
  insertBefore(c, ref) { const i = ref ? this.childNodes.indexOf(ref) : -1; if (i < 0) this.childNodes.push(c); else this.childNodes.splice(i, 0, c); c.parentNode = this; return c }
  removeChild(c) { this.childNodes = this.childNodes.filter(x => x !== c); c.parentNode = null; return c }
  remove() { this.parentNode?.removeChild(this) }
  setAttribute(k, v) { this.attributes[k] = v }
  removeAttribute(k) { delete this.attributes[k] }
  get firstChild() { return this.childNodes[0] ?? null }
  get nextSibling() { const p = this.parentNode; return p ? p.childNodes[p.childNodes.indexOf(this) + 1] ?? null : null }
}

test("a screen looks again on its own while in front, when it comes back to the front, and not while hidden", async () => {
  const e = env()
  const doc = new Node(9, "#document")
  doc.createElement = n => new Node(1, n); doc.createTextNode = t => Object.assign(new Node(3, "#text"), { data: t })
  const host = new Node(1, "div")
  let looks = 0
  const Probe = () => { useAutoLook(() => { looks++ }, { every: 20 }); return null }
  try {
    await act(() => render(h(Probe), host))
    await new Promise(r => setTimeout(r, 70))
    assert.ok(looks >= 1, `looked ${looks} times in ~3 periods`)
    e.doc.hidden = true
    const hiddenAt = looks
    await new Promise(r => setTimeout(r, 70))
    assert.equal(looks, hiddenAt, "nothing while the page is hidden")
    e.doc.hidden = false
    await act(() => render(null, host))
    const gone = looks
    await new Promise(r => setTimeout(r, 50))
    assert.equal(looks, gone, "stops when the screen goes")
    assert.ok(!e.on.has("online") && !e.docOn.has("visibilitychange"), "listeners removed")
  } finally { e.restore() }
})

test("coming back to the front looks at once, without waiting for the next period", async () => {
  const e = env()
  const host = new Node(1, "div")
  let looks = 0
  const Probe = () => { useAutoLook(() => { looks++ }, { every: 60_000 }); return null }
  try {
    await act(() => render(h(Probe), host))
    assert.equal(looks, 0, "no look on its own before a period")
    e.doc.hidden = true
    e.docOn.get("visibilitychange")()
    await new Promise(r => setTimeout(r, 0))
    assert.equal(looks, 0, "going to the back is not a look")
    e.doc.hidden = false
    e.docOn.get("visibilitychange")()
    await new Promise(r => setTimeout(r, 0))
    assert.equal(looks, 1, "back in front: one look")
    e.on.get("online")()
    await new Promise(r => setTimeout(r, 0))
    assert.equal(looks, 2, "back online: one look")
    await act(() => render(null, host))
  } finally { e.restore() }
})
