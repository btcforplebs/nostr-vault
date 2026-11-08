// Asking before a page with unsaved edits is left (Settings › Media Servers, as iPhone/Mac MediaServersLeaveGuard and
// Android's Back dialog). Every way out of a page here is a hash change (‹ Settings, the rail, the browser's Back), so
// the guard watches hashchange. It has to hear it before the app's router (main.jsx), nav-depth and chrome-fold do,
// and a capture flag doesn't do that on window (Chrome runs window listeners in the order they were added). So this
// module adds its one listener as it loads, before main.jsx's body or any component runs, and the page that needs it
// sets the guard. While the guard's `isDirty()`, a hash change stops there, history goes back to the page's own entry
// (so no copy of it is left for Back to land on), and the wanted address goes to `ask`; `leave(to)` then goes there without asking (after Save or
// Discard). Closing or reloading the tab gets the browser's own prompt.

const guards = new WeakMap() // window -> its guard, or nothing
// nav-depth.js numbers each history entry (history.state.nvDepth) as the router sees it. The guard runs first, so an
// entry a tap or link just made has none yet.
const depthOf = win => win.history.state?.nvDepth

/** Adds the window's hashchange and beforeunload listeners, once. Done as the module loads for the real window. */
export function watchLeaving(win) {
  if (guards.has(win)) return
  guards.set(win, null)
  win.addEventListener("hashchange", e => guards.get(win)?.onHash(e))
  win.addEventListener("beforeunload", e => guards.get(win)?.onUnload(e))
}
if (typeof window !== "undefined" && window.addEventListener) watchLeaving(window)

/** Guards `win` (the window; a fake in the tests) for one page. Returns { leave(to), stop() }. */
export function guardLeave(win, { isDirty, ask }) {
  watchLeaving(win)
  let at = win.location.href
  let atDepth = depthOf(win)
  let free = false
  const guard = {
    onHash(e) {
      const to = win.location.href
      if (free || !isDirty() || to === at) {
        // nav-depth numbers a new entry after this listener, so its number is read once the event is done.
        free = false; at = to; atDepth = depthOf(win)
        win.setTimeout(() => { if (win.location.href === at) atDepth = depthOf(win) }, 0)
        return
      }
      e.stopImmediatePropagation()
      // Back to the page's entry: a new entry (a link, a tap) is one step on; Back or Forward landed on a numbered one.
      // Going there fires a hashchange for the page's own address, which passes. With no numbers, the address is put
      // back in place instead.
      const d = depthOf(win)
      const steps = d == null ? -1 : atDepth == null ? 0 : atDepth - d
      if (steps) win.history.go(steps)
      else win.history.replaceState(win.history.state, "", at)
      ask(to)
    },
    onUnload(e) { if (isDirty()) { e.preventDefault(); e.returnValue = "" } },
  }
  guards.set(win, guard)
  return {
    leave(to) { free = true; win.location.href = to },
    stop() { if (guards.get(win) === guard) guards.set(win, null) },
  }
}
