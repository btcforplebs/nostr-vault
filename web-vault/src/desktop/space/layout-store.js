// The signed-in account's saved layout (space-layout.js: Your space's panels and the left rail's pins), held once for
// the whole desktop so the rail and Your space draw the same copy and an edit in one shows in both. The rules are
// docs/SPACE_LAYOUT.md's: an edit is kept in this browser at once and sent to the user's own vault two seconds after
// the last one (net/space-sync.js), so a drag sends one event, not one per step. On sign-in, and when the tab is
// looked at again, the vault's copy is read: a newer one replaces this one; an older one is answered by sending this
// one, so the other devices catch up. A copy in a newer format, or one that can't be opened, is left alone: this
// browser keeps its own and writes nothing over it.
import { useEffect, useState } from "preact/hooks"
import { readLayout, writeLayout, normalize } from "./space-layout.js"
import { PANEL_IDS } from "./panel-ids.js"
import { pullLayout, pushLayout, newerLayout } from "../../net/space-sync.js"

export const PUSH_DELAY_MS = 2000
/** How often a look back at the tab asks the vault again, at most. */
export const PULL_EVERY_MS = 60_000

let held = { me: null, layout: null, hold: false } // hold: the vault's copy is newer-format or unreadable, don't send
const listeners = new Set()
let sync = null // { ctx, timer, send }

/** The layout for `me`, read from this browser the first time. */
export function currentLayout(me) {
  if (held.me !== me) held = { me, layout: readLayout(me, PANEL_IDS), hold: false }
  return held.layout
}

function set(me, layout) {
  held = { ...held, me, layout }
  writeLayout(me, layout)
  for (const f of listeners) f(layout)
}

/** Whether edits for `me` are being held back from the vault (its copy is newer-format or can't be opened). */
export const holding = me => held.me === me && held.hold

function schedule(me) {
  if (!sync || sync.ctx.session.pubkey !== me || held.hold) return
  clearTimeout(sync.timer)
  sync.timer = setTimeout(() => { sync.timer = null; sync.send() }, PUSH_DELAY_MS)
}

/** Apply an edit for `me` (fn: layout -> layout). Unchanged: nothing happens. Changed: kept, drawn, and sent. */
export function changeLayout(me, fn) {
  const before = currentLayout(me)
  const next = fn(before)
  if (next === before) return
  set(me, next)
  schedule(me)
}

/**
 * What the vault's copy says, for `me` (pullLayout's answer). -> "taken" (newer, now drawn), "kept" (this one is the
 * same or newer, and is sent when newer), "held" (newer format or unreadable: left alone) or "none".
 */
export function takeRemote(me, pulled, { now } = {}) {
  const local = currentLayout(me)
  if (pulled?.state === "unreadable") { held = { ...held, hold: true }; return "held" }
  if (pulled?.state !== "ok") return "none"
  const remote = normalize(pulled.layout, PANEL_IDS, { now })
  if (!remote) { held = { ...held, hold: true }; return "held" }
  if (newerLayout(local, remote) !== local) { set(me, remote); return "taken" }
  if (local.at > remote.at) schedule(me)
  return "kept"
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
    // A send checks the account is still the one that made the edit once the signer has sealed it.
    const sendCtx = { ...ctx, stillMe: pk => held.me === pk }
    sync = { ctx, timer: null, send: () => { if (!held.hold) pushLayout(sendCtx, currentLayout(me)).catch(() => {}) } }
    let live = true, last = 0
    const pull = () => {
      if (Date.now() - last < PULL_EVERY_MS) return
      last = Date.now()
      pullLayout(ctx).then(r => { if (live) takeRemote(me, r) }).catch(() => {})
    }
    pull()
    const onShow = () => { if (!document.hidden) pull() }
    document.addEventListener("visibilitychange", onShow)
    return () => {
      live = false
      document.removeEventListener("visibilitychange", onShow)
      // An edit still waiting goes out now, not never.
      if (sync?.timer) { clearTimeout(sync.timer); sync.send() }
      sync = null
    }
  }, [me])
}
