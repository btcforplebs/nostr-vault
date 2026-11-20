// Napplets in the app's own screens (plan NV_WEB_ONE_PLAN.md step 11): on for everyone on the desktop layout, off on
// the phone layout and a narrow window, which keep today's screens (Logen's call 5). There is no switch any more: the
// layout decides. main.jsx sets it on every render, before any screen reads it.
const OLD_KEY = "nv-napplets" // the old preview tick, cleared
let desk = false

/** Built with the desktop napplets on? Off in NV for Linux's build (NV_BOX=1), Logen 2026-11-20: its desktop layout keeps
 *  the phone's own screens, as the site did before step 11 ("minus step 11"). vite.config.js defines __NV_DESK_NAPPLETS__;
 *  NV_DESK_NAPPLETS=1 / =0 at build time overrides the default. Undefined (tests, no vite) is on, as on master. */
export const DESK_NAPPLETS = typeof __NV_DESK_NAPPLETS__ === "undefined" || __NV_DESK_NAPPLETS__ !== false

/** Whether the screens are the napplets: true while the desktop layout is showing, in a build with them on. */
export const nappletsOn = () => desk
/** main.jsx: the layout of this render (desktop or not). `built`: the build's switch, DESK_NAPPLETS. */
export const setDeskLayout = (on, built = DESK_NAPPLETS) => { desk = !!on && built }

/** The old preview switch is gone: a stored tick is cleared, and ?napplets=1 / ?napplets=0 in an old bookmark is taken
 *  out of the address without changing anything. Returns true when it took one out. */
export function forgetOldSwitch(loc = globalThis.location, store = globalThis.localStorage, hist = globalThis.history) {
  try { store?.removeItem(OLD_KEY) } catch {}
  let url
  try { url = new URL(loc.href) } catch { return false }
  if (!url.searchParams.has("napplets")) return false
  url.searchParams.delete("napplets")
  try { hist?.replaceState(hist.state, "", url.pathname + url.search + url.hash) } catch {}
  return true
}
