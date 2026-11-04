// The signed-in account's saved layout (space-layout.js: Your space's panels and the left rail's pins), held once for
// the whole desktop so the rail and Your space draw the same copy and an edit in one shows in both. The rules are
// docs/SPACE_LAYOUT.md's: an edit is kept in this browser at once and sent to the user's own vault two seconds after
// the last one (net/space-sync.js), so a drag sends one event, not one per step. On sign-in, and when the tab is
// looked at again, the vault's copy is read: a newer one replaces this one; an older one is answered by sending this
// one, so the other devices catch up. A copy in a newer format, or one that can't be opened, is left alone: this
// browser keeps its own and writes nothing over it. Nothing is sent for an account until its first read has settled
// (Tron, PR 1628): a fresh browser starts at the default layout, and an edit sent before the vault's copy came back
// would replace the iPad's pins with none. A read where no relay answered doesn't settle it; it is tried again. Edits
// made before the first read are replayed on whichever copy wins against this browser's starting one, so a quick
// click on a fresh browser (whose edit is "newer" than anything) can't win with a layout that never had the pins.
import { useEffect, useState } from "preact/hooks"
import { readLayout, writeLayout, normalize } from "./space-layout.js"
import { PANEL_IDS } from "./panel-ids.js"
import { pullLayout, pushLayout, newerLayout } from "../../net/space-sync.js"

export const PUSH_DELAY_MS = 2000
/** How often a look back at the tab asks the vault again, at most. */
export const PULL_EVERY_MS = 60_000
/** A read where no relay answered is tried again this soon. */
export const RETRY_MS = 30_000

// hold: the vault's copy is newer-format or unreadable, don't send. pulled: the first read for this account settled.
// base: the layout this browser started from; pending: the edits made since, until the first read settles.
let held = { me: null, layout: null, hold: false, pulled: false, base: null, pending: [] }
const listeners = new Set()
let sync = null // { ctx, timer, send }

/** The layout for `me`, read from this browser the first time. */
export function currentLayout(me) {
  if (held.me !== me) {
    const layout = readLayout(me, PANEL_IDS)
    held = { me, layout, hold: false, pulled: false, base: layout, pending: [] }
  }
  return held.layout
}

function set(me, layout) {
  held = { ...held, me, layout }
  writeLayout(me, layout)
  for (const f of listeners) f(layout)
}

/** Whether edits for `me` are being held back from the vault: its copy is newer-format or can't be opened, or it
 *  hasn't been read yet. */
export const holding = me => held.me !== me || held.hold || !held.pulled
const maySend = me => held.me === me && held.pulled && !held.hold

function schedule(me) {
  if (!sync || sync.ctx.session.pubkey !== me || !maySend(me)) return
  clearTimeout(sync.timer)
  sync.timer = setTimeout(() => { sync.timer = null; sync.send() }, sync.delay)
}

/** Apply an edit for `me` (fn: layout -> layout). Unchanged: nothing happens. Changed: kept, drawn, and sent. */
export function changeLayout(me, fn) {
  const before = currentLayout(me)
  const next = fn(before)
  if (next === before) return
  if (!held.pulled) held.pending.push(fn)
  set(me, next)
  schedule(me)
}

/**
 * What the vault's copy says, for `me` (pullLayout's answer). -> "taken" (newer, now drawn), "kept" (this one is the
 * same or newer, and is sent when newer), "held" (newer format or unreadable: left alone), "none" (none saved: this
 * one is sent once it has an edit) or "failed" (no relay answered: still not read, nothing may be sent).
 */
export function takeRemote(me, pulled, { now } = {}) {
  const local = currentLayout(me)
  const state = pulled?.state
  if (state === "failed" || !state) return "failed"
  if (state === "unreadable") { held = { ...held, hold: true, pulled: true, pending: [] }; return "held" }
  if (state === "none") {
    held = { ...held, pulled: true, pending: [] }
    if (local.at > 0) schedule(me) // edits made while it was being read go out now
    return "none"
  }
  const remote = normalize(pulled.layout, PANEL_IDS, { now })
  if (!remote) { held = { ...held, hold: true, pulled: true, pending: [] }; return "held" }
  const pending = held.pulled ? [] : held.pending
  // A copy read fine: an earlier refusal (a declined decrypt prompt) no longer holds edits back.
  held = { ...held, hold: false, pulled: true, pending: [] }
  if (pending.length) {
    // The first read, with edits made while it ran: they go on top of whichever copy is newer than the one this
    // browser started from, then out.
    const start = newerLayout(held.base, remote)
    set(me, pending.reduce((l, fn) => fn(l), start))
    schedule(me)
    return start === remote ? "taken" : "kept"
  }
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

/**
 * Starts the vault sync for the signed-in account: reads the vault's copy now, when the tab is looked at again (at
 * most once a minute) and, while no relay has answered, every RETRY_MS; lets edits be sent once a read has settled.
 * -> a stop function, which sends an edit still waiting. A read-only sign-in has no key to open or seal the vault's
 * copy, so it keeps this browser's only. `pull`, `push`, `delay`, `retry` and `doc` are for tests.
 */
export function startSync(ctx, { pull = pullLayout, push = pushLayout, delay = PUSH_DELAY_MS, retry = RETRY_MS, doc = globalThis.document } = {}) {
  if (ctx.signer?.readOnly || !ctx.signer?.crypto) return () => {}
  const me = ctx.session.pubkey
  currentLayout(me)
  // A send checks the account is still the one that made the edit once the signer has sealed it.
  const sendCtx = { ...ctx, stillMe: pk => held.me === pk }
  sync = { ctx, delay, timer: null, send: () => { if (maySend(me)) push(sendCtx, currentLayout(me)).catch(() => {}) } }
  let live = true, last = 0, again = null
  const read = () => {
    last = Date.now()
    clearTimeout(again)
    pull(ctx).then(r => {
      if (!live) return
      if (takeRemote(me, r) === "failed") again = setTimeout(read, retry)
    }).catch(() => { if (live) again = setTimeout(read, retry) })
  }
  read()
  const onShow = () => { if (!doc.hidden && Date.now() - last >= PULL_EVERY_MS) read() }
  doc?.addEventListener?.("visibilitychange", onShow)
  return () => {
    live = false
    clearTimeout(again)
    doc?.removeEventListener?.("visibilitychange", onShow)
    // An edit still waiting goes out now, not never (only if a read has settled).
    if (sync?.timer) { clearTimeout(sync.timer); sync.send() }
    sync = null
  }
}

/** Mounted once by the desktop (DesktopShell.jsx): the sync for the signed-in account (startSync). */
export function useLayoutSync(ctx) {
  useEffect(() => startSync(ctx), [ctx.session.pubkey])
}
