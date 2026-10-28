// "Update ready, tap to reload". A new build's service worker installs beside the one serving this page and waits
// (public/sw.js), so this page's lazy chunks stay in the cache. The page is told once one waits; a tap starts it,
// and the page reloads onto it.
const CHECK_EVERY = 30 * 60_000 // a tab left open asks for a new build this often, and when it comes back into view

let ready = false, apply = () => location.reload()
const listeners = new Set()
/** Calls `f(ready)` now and on every change. -> stop */
export function onUpdateReady(f) { listeners.add(f); f(ready); return () => listeners.delete(f) }
/** The bar's tap: starts the waiting worker, then reloads. */
export const applyUpdate = () => apply()
const show = () => { if (!ready) { ready = true; for (const f of listeners) f(true) } }

/**
 * Watches `reg` (a ServiceWorkerRegistration) on `sw` (navigator.serviceWorker). `env` stands in for the page in tests.
 * - A worker already waiting when this page loads: this page was just served the new build (index.html is network
 *   first, and the waiting worker stored the new shell offline), so it starts that worker quietly, with no bar.
 * - One that finishes installing while this page runs: the bar.
 * - A newer worker taking over without this page asking (another tab tapped): the bar, as this page is the old build.
 */
// The timers are wrapped, not passed bare: env.every(...) calls its function as a method of env, and a browser's
// setInterval / setTimeout called with any `this` but the window throws "Illegal invocation".
const pageEnv = () => ({ reload: () => location.reload(), doc: document, every: (f, ms) => setInterval(f, ms), after: (f, ms) => setTimeout(f, ms), now: () => Date.now() })
export function watchUpdates(reg, sw, env = pageEnv()) {
  const hadController = !!sw.controller
  let asked = false
  apply = () => {
    if (!reg.waiting) return env.reload()
    asked = true
    reg.waiting.postMessage("skip-waiting")
    env.after(env.reload, 3000) // a worker that never takes over still gets the page onto the new build
  }
  sw.addEventListener("controllerchange", () => { if (asked) env.reload(); else if (hadController) show() })
  if (reg.waiting && hadController) reg.waiting.postMessage("skip-waiting")
  reg.addEventListener("updatefound", () => {
    const w = reg.installing
    w?.addEventListener("statechange", () => { if (w.state === "installed" && sw.controller) show() })
  })
  let last = env.now()
  const check = () => { if (env.now() - last >= CHECK_EVERY) { last = env.now(); reg.update().catch(() => {}) } }
  env.every(check, CHECK_EVERY)
  env.doc.addEventListener("visibilitychange", () => { if (env.doc.visibilityState === "visible") check() })
}
