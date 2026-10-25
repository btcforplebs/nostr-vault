// The phone's scroll-linked fold (src/components/chrome-fold.js), against the iPhone's rules (ChromeCollapse.swift,
// ScrollChromeModifier.swift): 1:1 with the finger over 60px, never past offset/60, settles to the nearer end, a fast
// fling commits, a jump to the top shows the bars; and the desktop layout is left alone (styles/chrome-fold.css).
import test from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { foldTracker, spring, startChromeFold, DISTANCE } from "../src/components/chrome-fold.js"

const track = () => {
  const calls = []
  const t = foldTracker((p, animated) => calls.push({ p, animated }))
  return { t, calls }
}
// A drag from `from` to `to` in `steps` scroll events `ms` apart, finger down the whole time.
function drag(t, from, to, { steps = 10, ms = 50, t0 = 0, release = true } = {}) {
  t.onTouch(true)
  for (let i = 0; i <= steps; i++) t.onScroll(from + (to - from) * i / steps, t0 + i * ms)
  if (release) t.onTouch(false)
  return t0 + steps * ms
}

const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} != ${b}`)

test("the fold follows the finger 1:1 over one bar height, and back", () => {
  const { t } = track()
  t.onScroll(200, 0)
  drag(t, 200, 230, { release: false })
  near(t.progress, 30 / DISTANCE)
  drag(t, 230, 215, { t0: 1000, release: false })
  near(t.progress, 15 / DISTANCE)
})

test("near the top the bars can only fold partway, and settle back open", () => {
  const { t, calls } = track()
  t.onScroll(0, 0)
  drag(t, 0, 40, { ms: 200 }) // slow: no fling
  assert.ok(t.progress <= 40 / DISTANCE + 1e-9)
  t.idle()
  assert.equal(t.progress, 0)
  assert.equal(calls.at(-1).animated, true)
})

test("released past halfway it settles folded; short of halfway, open", () => {
  const a = track()
  a.t.onScroll(300, 0)
  drag(a.t, 300, 340, { ms: 200 })
  a.t.idle()
  assert.equal(a.t.progress, 1)
  const b = track()
  b.t.onScroll(300, 0)
  drag(b.t, 300, 320, { ms: 200 })
  b.t.idle()
  assert.equal(b.t.progress, 0)
})

test("a fast fling commits to its direction at once, and its deceleration no longer moves the bars", () => {
  const { t, calls } = track()
  t.onScroll(500, 0)
  const end = drag(t, 500, 510, { steps: 2, ms: 10 }) // 1000 px/s down
  assert.equal(t.progress, 1)
  assert.equal(calls.at(-1).animated, true)
  t.onScroll(505, end + 16) // the fling's own movement, even backwards, does nothing
  assert.equal(t.progress, 1)
  const up = drag(t, 505, 495, { steps: 2, ms: 10, t0: end + 500 })
  assert.equal(t.progress, 0)
  t.onScroll(520, up + 16)
  assert.equal(t.progress, 0)
})

test("a scroll nobody's finger made (back to the top, a jump) shows the bars as the top comes near", () => {
  const { t } = track()
  t.onScroll(400, 0)
  drag(t, 400, 500, { ms: 200 }); t.idle()
  assert.equal(t.progress, 1)
  t.onScroll(400, 5000)
  assert.equal(t.progress, 1) // far from the top, a programmatic scroll leaves them
  t.onScroll(30, 5016)
  assert.ok(Math.abs(t.progress - 0.5) < 1e-9)
  t.onScroll(0, 5032)
  assert.equal(t.progress, 0)
})

test("reset opens the bars, animated", () => {
  const { t, calls } = track()
  t.onScroll(400, 0)
  drag(t, 400, 500, { ms: 200 }); t.idle()
  t.reset()
  assert.equal(t.progress, 0)
  assert.deepEqual(calls.at(-1), { p: 0, animated: true })
})

test("the spring lands exactly on its target without overshooting much (Motion.chrome, damping 0.86)", () => {
  let clock = 0, frames = []
  const queue = []
  spring(0, 1, v => frames.push(v), { raf: f => queue.push(f), caf: () => {}, now: () => clock })
  while (queue.length && clock < 5000) { clock += 16; queue.shift()() }
  assert.equal(frames.at(-1), 1)
  assert.ok(Math.max(...frames) < 1.03, `overshoot ${Math.max(...frames)}`)
  assert.ok(clock < 1000, `settled in ${clock} ms`)
})

test("start marks <html>, folds on a drag, and stop puts everything back", () => {
  const listeners = {}
  const props = {}
  const root = { dataset: {}, scrollHeight: 5000, style: { setProperty: (k, v) => { props[k] = v }, getPropertyValue: k => props[k] ?? "", removeProperty: k => { delete props[k] } } }
  const win = {
    document: { documentElement: root }, innerHeight: 800, scrollY: 1000,
    addEventListener: (k, f) => { listeners[k] = f }, removeEventListener: k => { delete listeners[k] },
    matchMedia: () => ({ matches: true }),
  }
  const stop = startChromeFold(win)
  assert.equal(root.dataset.fold, "open")
  assert.equal(props["--fold"], "0")
  listeners.touchstart({ touches: [{}] })
  win.scrollY = 1045; listeners.scroll()
  assert.equal(props["--fold"], "0.75")
  assert.equal(root.dataset.fold, "folded")
  stop()
  assert.equal(root.dataset.fold, undefined)
  assert.equal(props["--fold"], undefined)
  assert.deepEqual(Object.keys(listeners), [])
})

test("the desktop layout is untouched: every feed-bar rule needs html[data-fold], which only the phone layout sets", () => {
  const css = readFileSync(new URL("../src/styles/chrome-fold.css", import.meta.url), "utf8").replace(/\/\*[\s\S]*?\*\//g, "")
  for (const rule of css.split("}").map(r => r.trim()).filter(r => /feed-/.test(r))) assert.match(rule, /^html\[data-fold/, rule)
  // With no --fold every derived value is the unfolded one.
  assert.match(css, /var\(--fold, 0\)/)
  assert.doesNotMatch(css, /var\(--fold\)/)
  // The folded toolbar slides right by its own width; the header clips it so the page stays as wide as the screen.
  assert.match(css, /html\[data-fold\] \.feed-head \{ overflow-x: clip; \}/)
  const main = readFileSync(new URL("../main.jsx", import.meta.url), "utf8")
  assert.match(main, /mode === "phone" && session \? startChromeFold\(\)/)
})
