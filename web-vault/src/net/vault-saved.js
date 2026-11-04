// "Haven just kept something" for the page (Logen, 2026-11-04): Live Vault reads again as soon as a line's events are
// saved, not on its 60 s poll. haven/vault.js routeClient calls savedOne after each event Haven accepts; a duplicate
// or a refusal isn't news. No styles or Haven imports, so tests can use it.

const listeners = new Set()

/** cb(route, ev) after Haven accepted `ev` on `route` ("/", "/inbox"…). -> unsubscribe */
export function onSaved(cb) { listeners.add(cb); return () => listeners.delete(cb) }

export function savedOne(route, ev) { for (const cb of listeners) try { cb(route, ev) } catch {} }

/**
 * `fn` at most once per `gapMs`, the last call within a gap carried to its end, so a burst (an import of thousands)
 * costs a read every gap, not one per event. `timers` is for tests. -> { call, stop }
 */
export function throttle(fn, gapMs, { now = () => Date.now(), set = setTimeout, clear = clearTimeout } = {}) {
  let last = -Infinity, timer = null
  const run = () => { timer = null; last = now(); fn() }
  return {
    call() {
      if (timer) return
      const wait = last + gapMs - now()
      if (wait <= 0) run(); else timer = set(run, wait)
    },
    stop() { if (timer) clear(timer); timer = null },
  }
}
