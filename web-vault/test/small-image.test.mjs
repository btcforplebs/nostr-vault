// small-image.js (perf audit 2026-11-20 L2, L3): avatars and feed photos are drawn at the size shown, never larger.
import test from "node:test"
import assert from "node:assert/strict"
import { scaleFor, stillOf } from "../src/components/small-image.js"

test("cover fills the slot, contain fits inside it, and nothing is ever enlarged", () => {
  assert.equal(scaleFor(4000, 3000, { w: 80, h: 80 }, "cover"), 80 / 3000)
  assert.equal(scaleFor(4000, 3000, { w: 80, h: 80 }, "contain"), 80 / 4000)
  assert.equal(scaleFor(1200, 3600, { w: 1200, h: 800 }, "contain"), 800 / 3600, "a tall photo stops at the slot's height")
  assert.equal(scaleFor(64, 64, { w: 80, h: 80 }, "cover"), 1)
})

test("where it can't be drawn small (no createImageBitmap) the original is drawn, and nothing is fetched", async () => {
  const was = globalThis.fetch
  let asked = 0
  globalThis.fetch = async () => { asked++; throw new Error("fetched") }
  try {
    assert.deepEqual(await stillOf("https://media.example/a.gif", { w: 40, h: 40 }, "cover"), { src: null, animated: false })
    assert.equal(asked, 0)
  } finally { globalThis.fetch = was }
})

// useSmallSrc with a stand-in for preact/hooks: real state and effects with deps, so a test can play what Preact does
// when it puts a new DOM node under the same component (the old node is detached; the component and its effect stay).
// 2026-11-20: the hook watched the node it saw first, so on Logen's Notifications 37-79 faces stayed on the grey
// placeholder for good: the detached node never comes into view.
const hooks = globalThis.__testHooks = (() => {
  let slots = [], at = 0, dirty = false, pending = []
  const same = (a, b) => a && b && a.length === b.length && a.every((x, i) => Object.is(x, b[i]))
  return {
    useState(init) {
      const i = at++
      if (!(i in slots)) {
        const cell = { v: typeof init === "function" ? init() : init }
        cell.set = v => { const n = typeof v === "function" ? v(cell.v) : v; if (!Object.is(n, cell.v)) { cell.v = n; dirty = true } }
        slots[i] = cell
      }
      return [slots[i].v, slots[i].set]
    },
    useRef(v) { const i = at++; if (!(i in slots)) slots[i] = { current: v ?? null }; return slots[i] },
    useEffect(fn, deps) {
      const i = at++, old = slots[i]
      if (!old || !deps || !same(old.deps, deps)) { pending.push(() => { old?.cleanup?.(); slots[i] = { deps, cleanup: fn() } }) }
    },
    reset() { slots = []; at = 0; dirty = false; pending = [] },
    /** One render as Preact commits it: the component runs, `commit(out)` puts its nodes (refs) in, then effects run. */
    render(component, commit = () => {}) { let out; do { dirty = false; at = 0; pending = []; out = component(); commit(out); for (const run of pending) run() } while (dirty); return out },
  }
})()
const { registerHooks } = await import("node:module")
registerHooks({
  resolve(spec, context, next) {
    if (spec === "preact/hooks" && context.parentURL?.includes("small-image.js")) {
      return { url: "data:text/javascript," + encodeURIComponent("const h = globalThis.__testHooks; export const useState = (...a) => h.useState(...a), useEffect = (...a) => h.useEffect(...a), useRef = (...a) => h.useRef(...a)"), shortCircuit: true }
    }
    return next(spec, context)
  },
})
const { useSmallSrc } = await import("../src/components/small-image.js?hooks")

/** An IntersectionObserver whose test says which node comes into view. */
function fakeObservers() {
  const all = new Set()
  globalThis.IntersectionObserver = class { constructor(cb) { this.cb = cb; this.nodes = new Set(); all.add(this) } observe(n) { this.nodes.add(n) } disconnect() { this.nodes.clear(); all.delete(this) } }
  return { watched: () => [...all].flatMap(o => [...o.nodes]), show: node => { for (const o of [...all]) if (o.nodes.has(node)) o.cb([{ target: node, isIntersecting: true }]) } }
}
/** What Preact does with a ref: a function is called with the node (null when it goes), an object gets .current. */
const attach = (ref, node) => (typeof ref === "function" ? ref(node) : (ref.current = node))

test("a picture whose placeholder node is replaced still loads when the new node comes into view", async () => {
  hooks.reset()
  const io = fakeObservers(), first = { id: "first" }, second = { id: "second" }
  const draw = () => useSmallSrc("https://media.example/a.jpg", { box: { w: 30, h: 30 } })
  let node = first
  const commit = out => attach(out.ref, node)
  let out = hooks.render(draw, commit)
  assert.deepEqual(io.watched(), [first])
  assert.equal(out.ready, false)
  // Preact swaps the node: the old one is detached, the component and its effect stay.
  attach(out.ref, null)
  node = second
  out = hooks.render(draw, commit)
  assert.deepEqual(io.watched(), [second], "only the node on the page is watched")
  io.show(second)
  await new Promise(r => setTimeout(r, 0))
  out = hooks.render(draw, commit)
  assert.equal(out.ready, true, "the face leaves the grey placeholder")
  delete globalThis.IntersectionObserver
})
