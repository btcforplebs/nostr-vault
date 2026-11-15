// Napplets in the app's own screens (plan P2 on): off unless switched on, by the tick on the napplet shell page
// (/vault/?shell=1) or by the address itself: /vault/?napplets=1 turns them on, ?napplets=0 off, signed in or not
// (main.jsx reads it before the sign-in screen). While off, each screen keeps its old panel (the plan's "old screen
// stays behind a switch for one release").
const KEY = "nv-napplets"
export const nappletsOn = (store = globalThis.localStorage) => { try { return store?.getItem(KEY) === "1" } catch { return false } }
export const setNappletsOn = (on, store = globalThis.localStorage) => { try { on ? store.setItem(KEY, "1") : store.removeItem(KEY) } catch {} }

/** ?napplets=1 / ?napplets=0 in the page address: set the switch, then take the word out of the address (so a
 *  bookmark or a reload doesn't keep flipping it back). Returns true/false when it switched, null when the address has
 *  no ?napplets. Any other value is ignored and left in place. */
export function switchFromAddress(loc = globalThis.location, store = globalThis.localStorage, hist = globalThis.history) {
  let url
  try { url = new URL(loc.href) } catch { return null }
  const v = url.searchParams.get("napplets")
  if (v !== "1" && v !== "0") return null
  setNappletsOn(v === "1", store)
  url.searchParams.delete("napplets")
  try { hist?.replaceState(hist.state, "", url.pathname + url.search + url.hash) } catch {}
  return v === "1"
}
