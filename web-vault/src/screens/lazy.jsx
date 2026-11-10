// Screens loaded when they are first shown. The boot bundle carries the app around them and the Feed (what nearly
// every visit opens on); each other screen is its own chunk, fetched the first time its route is drawn. Before this
// the whole app was one 1.47 MB script (468 kB gz, no splitting) that had to arrive and parse before the feed could
// draw (NV_HEALTH_F_WEB). Two things still add no code here: the phone layout (main.jsx) and the desktop one
// (desktop/DesktopShell.jsx) both render these same wrappers, and a screen is asked for once per page (a chunk
// already loaded mounts with no flash, and a chunk that failed is asked for again next time).
import { useEffect, useState } from "preact/hooks"
import { SkeletonList } from "../components/Loading.jsx"

const chunks = new Map() // export name -> promise of the component
const loaded = new Map() // export name -> the component, once it is in hand

/** `loader()` once per screen: the promise, and its component once it resolves (and its stylesheets are in). */
function once(key, loader) {
  if (!chunks.has(key)) {
    const p = loader().then(async m => {
      if (typeof m[key] !== "function") throw new Error(`${key} isn't exported by its chunk`)
      await sheetsIn()
      loaded.set(key, m[key])
      return m[key]
    })
    p.catch(() => chunks.delete(key)) // a chunk that didn't load (offline, a deploy mid-visit) is asked for next time
    chunks.set(key, p)
  }
  return chunks.get(key)
}

/** How long a screen waits for its stylesheets before it draws anyway. */
export const SHEET_WAIT_MS = 3000

/**
 * The stylesheets still loading, in. A chunk's modules ask for their sheets as they run
 * (`if (import.meta.env) import("x.css")`), and the bundler adds each one's <link> to the page right then, before the
 * chunk's import resolves; nothing waited for them, so a screen drew unstyled and then jumped when they landed. A
 * sheet that fails, or takes longer than SHEET_WAIT_MS, doesn't hold the screen.
 */
export function sheetsIn(doc = globalThis.document, ms = SHEET_WAIT_MS) {
  if (!doc?.querySelectorAll) return Promise.resolve()
  const pending = [...doc.querySelectorAll('link[rel="stylesheet"]')].filter(l => !l.sheet)
  if (!pending.length) return Promise.resolve()
  const each = pending.map(l => new Promise(r => { l.addEventListener("load", r, { once: true }); l.addEventListener("error", r, { once: true }) }))
  let timer
  return Promise.race([Promise.all(each), new Promise(r => { timer = setTimeout(r, ms) })]).finally(() => clearTimeout(timer))
}

/** What a screen shows while its chunk loads: the screen's own box with placeholder rows, never an empty page. */
export function ScreenLoading() {
  return <main class="screen" aria-busy="true"><SkeletonList label="Loading…" /></main>
}

/** A screen whose chunk didn't load (offline, or a deploy replaced it): says so, and tries again on the button or
 *  when the browser is back online. */
export function ScreenFailed({ onRetry }) {
  const offline = typeof navigator !== "undefined" && navigator.onLine === false
  return <main class="screen">
    <p class="error" role="alert">{offline ? "You're offline, so this screen couldn't load." : "This screen didn't load."}</p>
    <button type="button" onClick={onRetry}>Try again</button>
  </main>
}

/**
 * The screen `key` (its export name) from `loader` (a static dynamic import of its module, so the bundler splits it).
 * Renders `fallback` while the chunk loads and `failed` if it couldn't (ScreenLoading and ScreenFailed unless told
 * otherwise), and nothing extra for a screen already loaded.
 */
export function lazyScreen(key, loader, { fallback: Fallback = ScreenLoading, failed: Failed = ScreenFailed } = {}) {
  const Lazy = props => {
    const [Comp, setComp] = useState(() => loaded.get(key) ?? null)
    const [failed, setFailed] = useState(false)
    const [round, setRound] = useState(0)
    useEffect(() => {
      if (Comp) return
      let live = true
      setFailed(false)
      once(key, loader).then(c => { if (live) setComp(() => c) }, () => { if (live) setFailed(true) })
      return () => { live = false }
    }, [round])
    // Back online: ask again by itself.
    useEffect(() => {
      if (!failed || typeof addEventListener === "undefined") return
      const f = () => setRound(r => r + 1)
      addEventListener("online", f)
      return () => removeEventListener("online", f)
    }, [failed])
    if (Comp) return <Comp {...props} />
    return failed ? <Failed onRetry={() => setRound(r => r + 1)} /> : <Fallback />
  }
  Lazy.displayName = `Lazy(${key})`
  /** Starts the chunk now, for a screen about to be shown (or a link that opens one). */
  Lazy.load = () => once(key, loader)
  return Lazy
}
