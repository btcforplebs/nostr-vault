// Switch Account from the avatar (iPhone BottomTabBar accountSwitchButton): a still hold of HOLD_MS opens it, so does
// a right-click or the context-menu key; a tap, a scroll or a secondary button doesn't; the click ending a hold doesn't
// follow the link. The sidebar names the real sign-in kind, not "Owner key" for every signer.
import test from "node:test"
import assert from "node:assert/strict"
import { registerHooks } from "node:module"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { transformSync } from "rolldown/utils"

registerHooks({
  load(url, context, next) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true }
    if (!url.endsWith(".jsx")) return next(url, context)
    const path = fileURLToPath(url)
    const { code, errors } = transformSync(path, readFileSync(path, "utf8"), { jsx: { runtime: "automatic", importSource: "preact" } })
    if (errors.length) throw new Error(errors.map(e => e.message).join("\n"))
    return { format: "module", source: code, shortCircuit: true }
  },
})
const { holdHandlers, HOLD_MS } = await import("../src/components/AccountSwitch.jsx")

const fakeTimers = () => {
  let next = 1, pending = new Map()
  return {
    setTimeout: (fn, ms) => { pending.set(next, { fn, ms }); return next++ },
    clearTimeout: id => pending.delete(id),
    run: () => { const all = [...pending.values()]; pending.clear(); all.forEach(t => t.fn()); return all.map(t => t.ms) },
  }
}
const ev = (o = {}) => ({ button: 0, clientX: 10, clientY: 10, prevented: false, stopped: false, preventDefault() { this.prevented = true }, stopPropagation() { this.stopped = true }, ...o })

test("a still hold opens the menu after the iPhone's 0.4 s, and its click doesn't follow the link", () => {
  const timers = fakeTimers()
  let opened = 0
  const h = holdHandlers(() => opened++, { timers })
  h.onPointerDown(ev())
  assert.deepEqual(timers.run(), [HOLD_MS])
  assert.equal(HOLD_MS, 400)
  assert.equal(opened, 1)
  const click = ev()
  h.onClickCapture(click)
  assert.equal(click.prevented && click.stopped, true)
  const next = ev()
  h.onClickCapture(next)
  assert.equal(next.prevented, false, "only the click that ended the hold")
})

test("a tap, a drag past the slop, or a secondary button opens nothing and the tap still goes through", () => {
  const timers = fakeTimers()
  let opened = 0
  const h = holdHandlers(() => opened++, { timers })
  h.onPointerDown(ev()); h.onPointerUp(ev()); timers.run()
  h.onPointerDown(ev()); h.onPointerMove(ev({ clientX: 30 })); timers.run()
  h.onPointerDown(ev({ button: 2 })); timers.run()
  assert.equal(opened, 0)
  const click = ev()
  h.onClickCapture(click)
  assert.equal(click.prevented, false)
  h.onPointerDown(ev()); h.onPointerMove(ev({ clientX: 14, clientY: 13 })); timers.run()
  assert.equal(opened, 1, "a wobble inside the slop is still a hold")
})

test("a right-click or the context-menu key opens it at once, without the browser's menu", () => {
  let opened = 0
  const h = holdHandlers(() => opened++, { timers: fakeTimers() })
  const e = ev()
  h.onContextMenu(e)
  assert.equal(opened, 1)
  assert.equal(e.prevented, true)
})

test("the sidebar names the sign-in kind; the tab bar's avatars carry the hold", () => {
  const src = f => readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")
  assert.doesNotMatch(src("desktop/Sidebar.jsx"), /Owner key/)
  assert.match(src("desktop/Sidebar.jsx"), /signer\?\.readOnly \? "Read-only" : methodLabel\(session\)/)
  const bar = src("components/TabBar.jsx")
  assert.match(bar, /id === "profile" \? \{ \.\.\.holdProps/)
  assert.match(bar, /class="fold-avatar tab-avatar-hold"[^>]*\{\.\.\.holdProps\}/)
})
