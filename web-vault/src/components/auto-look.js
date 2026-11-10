// Screens look again on their own, as other Nostr clients do (no Refresh buttons in the web app, Logen 2026-11-04):
// every `every` ms while the page is in front, and when it comes back to the front or online. Not while it is hidden
// or offline. The newest `look` is called; a look still running is not started again.
import { useEffect, useRef } from "preact/hooks"

/**
 * `look()` -> maybe a promise, called every `every` ms while the page is in front, and once when it comes back to the
 * front or online. Not while it is hidden or offline (a hidden tab asking relays for a panel nobody can see is the
 * battery and the relay budget spent for nothing), and not twice at once. `on`: false pauses. -> stop()
 *
 * The plain function, for effects that already own their `look`; useAutoLook is this plus a stable callback.
 */
export function lookInFront(look, { every = 60_000, on = true, doc = globalThis.document } = {}) {
  if (!on || !globalThis.addEventListener) return () => {}
  let busy = false
  const run = () => {
    if (busy || doc?.hidden || globalThis.navigator?.onLine === false) return
    busy = true
    Promise.resolve().then(() => look()).catch(() => {}).finally(() => { busy = false })
  }
  const t = setInterval(run, every)
  t.unref?.() // node (the tests) only
  const back = () => { if (!doc?.hidden) run() }
  globalThis.addEventListener("online", run)
  doc?.addEventListener?.("visibilitychange", back)
  return () => { clearInterval(t); globalThis.removeEventListener("online", run); doc?.removeEventListener?.("visibilitychange", back) }
}

/** `look()` -> maybe a promise. `every`: ms between looks while in front. `on`: false pauses. `deps`: start again. */
export function useAutoLook(look, { every = 60_000, on = true } = {}, deps = []) {
  const fn = useRef(look)
  fn.current = look
  useEffect(() => lookInFront(() => fn.current(), { every, on }), [on, every, ...deps])
}
