// The signed-in account's saved layout (space-layout.js: Your space's panels and the left rail's favourites), held
// once for the whole desktop so the rail and Your space draw the same copy and an edit in one shows in both. An edit is
// kept in this browser at once, then sent to the user's own vault two seconds after the last one (net/space-sync.js),
// so a drag sends one event, not one per step. A newer layout from the vault (another browser, later the iPad) replaces
// this one when it arrives.
import { useEffect, useState } from "preact/hooks"
import { readLayout, writeLayout, normalize } from "./space-layout.js"
import { PANEL_IDS } from "./panel-ids.js"
import { pullLayout, pushLayout, newerLayout } from "../../net/space-sync.js"

export const PUSH_DELAY_MS = 2000
/** How often a look back at the tab asks the vault again, at most. */
export const PULL_EVERY_MS = 60_000

let held = { me: null, layout: null }
const listeners = new Set()
let push = null // { timer, ctx }

/** The layout for `me`, read from this browser the first time. */
export function currentLayout(me) {
  if (held.me !== me) held = { me, layout: readLayout(me, PANEL_IDS) }
  return held.layout
}

function set(me, layout) {
  held = { me, layout }
  writeLayout(me, layout)
  for (const f of listeners) f(layout)
}

/** Apply an edit for `me` (fn: layout -> layout). Unchanged: nothing happens. Changed: kept, drawn, and sent. */
export function changeLayout(me, fn) {
  const before = currentLayout(me)
  const next = fn(before)
  if (next === before) return
  set(me, next)
  if (push?.ctx?.session?.pubkey === me) {
    clearTimeout(push.timer)
    const ctx = push.ctx
    push.timer = setTimeout(() => pushLayout(ctx, currentLayout(me)).catch(() => {}), PUSH_DELAY_MS)
  }
}

/** A layout read from the vault: taken when it is newer than the one held. -> whether it was taken. */
export function takeRemote(me, remote) {
  const local = currentLayout(me)
  const next = newerLayout(local, remote && normalize(remote, PANEL_IDS))
  if (next === local) return false
  set(me, next)
  return true
}

/** [layout, change] for `me`; re-renders on every edit, from here or the rail or the vault. */
export function useLayout(me) {
  const [, tick] = useState(0)
  useEffect(() => {
    const f = () => tick(t => t + 1)
    listeners.add(f)
    return () => listeners.delete(f)
  }, [])
  return [currentLayout(me), fn => changeLayout(me, fn)]
}

/** Mounted once by the desktop: reads the vault's copy on sign-in and when the tab is looked at again, and lets edits
 *  be sent. A read-only sign-in has no key to open or seal the vault's copy, so it keeps this browser's only. */
export function useLayoutSync(ctx) {
  const me = ctx.session.pubkey
  useEffect(() => {
    if (ctx.signer?.readOnly || !ctx.signer?.crypto) return
    push = { timer: null, ctx }
    let live = true, last = 0
    const pull = () => {
      if (Date.now() - last < PULL_EVERY_MS) return
      last = Date.now()
      pullLayout(ctx).then(remote => { if (live && remote) takeRemote(me, remote) }).catch(() => {})
    }
    pull()
    const onShow = () => { if (!document.hidden) pull() }
    document.addEventListener("visibilitychange", onShow)
    return () => {
      live = false
      document.removeEventListener("visibilitychange", onShow)
      // An edit still waiting goes out now, not never.
      if (push?.timer) { clearTimeout(push.timer); pushLayout(ctx, currentLayout(me)).catch(() => {}) }
      push = null
    }
  }, [me])
}
