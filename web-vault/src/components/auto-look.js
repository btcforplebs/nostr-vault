// Screens look again on their own, as other Nostr clients do (no Refresh buttons in the web app, Logen 2026-11-04):
// every `every` ms while the page is in front, and when it comes back to the front or online. Not while it is hidden
// or offline. The newest `look` is called; a look still running is not started again.
import { useEffect, useRef } from "preact/hooks"

/** `look()` -> maybe a promise. `every`: ms between looks while in front. `on`: false pauses. `deps`: start again. */
export function useAutoLook(look, { every = 60_000, on = true } = {}, deps = []) {
  const fn = useRef(look)
  fn.current = look
  useEffect(() => {
    if (!on || !globalThis.addEventListener) return
    let busy = false
    const run = () => {
      if (busy || globalThis.document?.hidden || globalThis.navigator?.onLine === false) return
      busy = true
      Promise.resolve().then(() => fn.current()).catch(() => {}).finally(() => { busy = false })
    }
    const t = setInterval(run, every)
    t.unref?.() // node (the tests) only
    const back = () => { if (!globalThis.document?.hidden) run() }
    addEventListener("online", run)
    globalThis.document?.addEventListener?.("visibilitychange", back)
    return () => { clearInterval(t); removeEventListener("online", run); globalThis.document?.removeEventListener?.("visibilitychange", back) }
  }, [on, every, ...deps])
}
