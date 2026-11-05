// The signed-in account's layout (space-layout.js: Your space's panels and the left rail's pins), held once for the
// whole desktop so the rail and Your space draw the same copy and an edit in one shows in both. Kept in this browser
// only (Logen 2026-11-05, RESEARCH/NV_APP_DATA_30078_2026_11_05.md): it used to sync through a NIP-78 event (kind
// 30078) on the user's relays, which cost a signature and an encryption per edit and a decrypt per tab refocus, so
// nothing about the layout is published, pulled or signed any more. The old events are left on the relays.
import { useEffect, useState } from "preact/hooks"
import { readLayout, writeLayout } from "./space-layout.js"
import { PANEL_IDS } from "./panel-ids.js"

let held = { me: null, layout: null }
const listeners = new Set()

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

/** This browser's saved copy when another tab of it saved an edit since this tab read it: an edit here starts from
 *  that one instead of writing over it (bug hunt 2026-11-05). */
function freshest(me) {
  const mine = currentLayout(me)
  let stored
  try { stored = readLayout(me, PANEL_IDS) } catch { return mine }
  if (!stored || (stored.at ?? 0) < (mine.at ?? 0) || JSON.stringify(stored) === JSON.stringify(mine)) return mine
  held = { ...held, layout: stored }
  return stored
}

/** Apply an edit for `me` (fn: layout -> layout). Unchanged: nothing happens. Changed: kept in this browser and drawn. */
export function changeLayout(me, fn) {
  const before = freshest(me)
  const next = fn(before)
  if (next === before) return
  set(me, next)
}

/** [layout, change] for `me`; re-renders on every edit, from here or the rail. */
export function useLayout(me) {
  const [, tick] = useState(0)
  useEffect(() => {
    const f = () => tick(t => t + 1)
    listeners.add(f)
    return () => listeners.delete(f)
  }, [])
  return [currentLayout(me), fn => changeLayout(me, fn)]
}
