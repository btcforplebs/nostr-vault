// The tab screens' chunks, fetched while the app sits idle once it's open, so the first click on a tab draws the
// screen and not a page of placeholder rows while its code comes in (lazy.jsx). One at a time, after the feed has
// had its turn; a data saver or a 2G link skips it, and a tab clicked first just loads as before.
import { SearchScreen, ProfileScreen, NotificationsScreen, MessagesScreen, VaultScreen, WotScreen, ThreadScreen } from "./lazy-screens.js"

export const WARM_ORDER = [SearchScreen, ProfileScreen, NotificationsScreen, MessagesScreen, ThreadScreen, VaultScreen, WotScreen]
export const WARM_START_MS = 2500

let started = false

/** Whether this connection is one to leave alone: a data saver on, or a 2G-class link. */
export function lightLink(nav = globalThis.navigator) {
  const c = nav?.connection
  return !!c && (c.saveData === true || /(^|-)2g$/.test(c.effectiveType ?? ""))
}

/** Starts warming once per page. `idle` and `wait` are swappable for tests. */
export function warmScreens({ screens = WARM_ORDER, nav = globalThis.navigator, wait = ms => new Promise(r => setTimeout(r, ms)),
  idle = () => new Promise(r => (globalThis.requestIdleCallback ?? (f => setTimeout(f, 50)))(() => r(), { timeout: 2000 })) } = {}) {
  if (started || lightLink(nav)) return null
  started = true
  return (async () => {
    await wait(WARM_START_MS)
    for (const s of screens) {
      await idle()
      await s.load().catch(() => {}) // a chunk that fails here is asked for again when its tab is opened
    }
  })()
}

/** Tests only. */
export const resetWarm = () => { started = false }
