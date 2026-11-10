// Screens loaded when they are first shown. The boot bundle carries the app around them and the Feed (what nearly
// every visit opens on); each other screen is its own chunk, fetched the first time its route is drawn. Before this
// the whole app was one 1.47 MB script (468 kB gz, no splitting) that had to arrive and parse before the feed could
// draw (NV_HEALTH_F_WEB). Two things still add no code here: the phone layout (main.jsx) and the desktop one
// (desktop/DesktopShell.jsx) both render these same wrappers, and a screen is asked for once per page (a chunk
// already loaded mounts with no flash, and a chunk that failed is asked for again next time).
import { useEffect, useState } from "preact/hooks"

const chunks = new Map() // export name -> promise of the component
const loaded = new Map() // export name -> the component, once it is in hand

/** `loader()` once per screen: the promise, and its component once it resolves. */
function once(key, loader) {
  if (!chunks.has(key)) {
    const p = loader().then(m => {
      if (typeof m[key] !== "function") throw new Error(`${key} isn't exported by its chunk`)
      loaded.set(key, m[key])
      return m[key]
    })
    p.catch(() => chunks.delete(key)) // a chunk that didn't load (offline, a deploy mid-visit) is asked for next time
    chunks.set(key, p)
  }
  return chunks.get(key)
}

/**
 * The screen `key` (its export name) from `loader` (a static dynamic import of its module, so the bundler splits it).
 * Renders `Fallback` for the frame or two before the chunk is in hand, and nothing at all for a screen already loaded.
 */
export function lazyScreen(key, loader, Fallback = () => null) {
  const Lazy = props => {
    const [Comp, setComp] = useState(() => loaded.get(key) ?? null)
    useEffect(() => {
      if (Comp) return
      let live = true
      once(key, loader).then(c => { if (live) setComp(() => c) }, () => {})
      return () => { live = false }
    }, [])
    return Comp ? <Comp {...props} /> : <Fallback />
  }
  Lazy.displayName = `Lazy(${key})`
  /** Starts the chunk now, for a screen about to be shown (or a link that opens one). */
  Lazy.load = () => once(key, loader)
  return Lazy
}
