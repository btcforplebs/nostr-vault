// The desktop layout (Logen, 2026-11-03): Your space's panels (which show, in what order, which are collapsed to their
// header) and the left rail's pins (rail/rail-favs.js). The format and every rule here are in docs/SPACE_LAYOUT.md,
// shared with the iPad (HavenApp/Models/SpaceLayout.swift); fix one of them if they disagree. No styles, so tests can
// import it. SpaceDock.jsx and Sidebar.jsx draw it; layout-store.js keeps it; net/space-sync.js syncs it.
//   { v: 1, at: <unix seconds of the last edit>, pins: [pin, ...], panels: [{ id, on, open }, ...], ...kept }
// Every top-level key, panel field and entry this app doesn't understand is kept exactly as read, so an older app and
// a newer one can share a layout.

import { defaultPins, normalizePins } from "../rail/rail-favs.js"

export const LAYOUT_V = 1
/** The NIP-78 `d` of the synced layout. */
export const SYNC_D = "nostr-vault-space-layout"

/** How far ahead of this clock `at` may be (the iPad's SpaceLayout.maxSkew): further ahead is pulled back to now plus
 *  this, so a device whose clock runs fast can't win every later comparison. */
export const MAX_SKEW_S = 15 * 60

/** The layout before any edit: the default pins, every panel in panels.js's order, shown and open. */
export const defaultLayout = (ids, at = 0) => ({ v: LAYOUT_V, at, pins: defaultPins(), panels: ids.map(id => ({ id, on: true, open: true })) })

/** `at` as whole seconds from 0 to `now + MAX_SKEW_S`; 0 when missing or not a number. */
export function clampAt(at, now = Math.floor(Date.now() / 1000)) {
  if (typeof at !== "number" || !Number.isFinite(at) || at <= 0) return 0
  return Math.min(Math.floor(at), now + MAX_SKEW_S)
}

/**
 * Any saved value -> a clean layout against the panel ids this app has (docs "Normalising"). Not an object, or `v` not
 * a whole number: the default. `v` above ours: null, a newer format to leave alone (draw the default, write nothing
 * over it). Otherwise every top-level key is kept; pins go through normalizePins; bad panel entries and repeats drop
 * out, unknown ids and fields stay, a missing known panel goes in after the known one before it (at the top when none
 * is), shown and open; `at` is clamped (clampAt).
 */
export function normalize(saved, ids, { now } = {}) {
  if (!saved || typeof saved !== "object" || Array.isArray(saved)) return defaultLayout(ids)
  const v = saved.v
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v !== Math.floor(v)) return defaultLayout(ids)
  if (v > LAYOUT_V) return null
  const seen = new Set(), panels = []
  for (const p of Array.isArray(saved.panels) ? saved.panels : []) {
    if (!p || typeof p !== "object" || Array.isArray(p) || typeof p.id !== "string" || !p.id || seen.has(p.id)) continue
    seen.add(p.id)
    panels.push({ ...p, on: p.on !== false, open: p.open !== false })
  }
  ids.forEach((id, i) => {
    if (seen.has(id)) return
    seen.add(id)
    const before = ids.slice(0, i).reverse().find(b => panels.some(p => p.id === b))
    const at = before ? panels.findIndex(p => p.id === before) + 1 : 0
    panels.splice(at, 0, { id, on: true, open: true })
  })
  return { ...saved, v: LAYOUT_V, at: clampAt(saved.at, now), pins: normalizePins(saved.pins), panels }
}

const now = () => Math.floor(Date.now() / 1000)
const edit = (layout, panels, at) => ({ ...layout, at: at ?? now(), panels })

/** The panels to draw, in order: shown and known. */
export const shownPanels = (layout, ids) => layout.panels.filter(p => p.on && ids.includes(p.id))
/** The known panels taken off, for "+ add", in panels.js's order. */
export const hiddenPanels = (layout, ids) => ids.filter(id => layout.panels.some(p => p.id === id && !p.on))

/** Reset Your space's panels (the pins stay as they are). */
export const resetPanels = (layout, ids, at) => edit(layout, defaultLayout(ids).panels, at)

/** Show or hide a panel. A panel shown again goes back where it was. */
export const setOn = (layout, id, on, at) => edit(layout, layout.panels.map(p => (p.id === id ? { ...p, on } : p)), at)
/** Open a panel or collapse it to its header. */
export const setOpen = (layout, id, open, at) => edit(layout, layout.panels.map(p => (p.id === id ? { ...p, open } : p)), at)

/**
 * Move a shown panel one place up (-1) or down (+1) among the drawn panels; hidden and unknown ones keep their
 * places in between. At the top or bottom nothing changes.
 */
export function moveBy(layout, id, delta, ids, at) {
  const drawn = shownPanels(layout, ids).map(p => p.id)
  const i = drawn.indexOf(id), j = i + delta
  if (i < 0 || j < 0 || j >= drawn.length) return layout
  const a = layout.panels.findIndex(p => p.id === id), b = layout.panels.findIndex(p => p.id === drawn[j])
  const panels = [...layout.panels]
  ;[panels[a], panels[b]] = [panels[b], panels[a]]
  return edit(layout, panels, at)
}

/** Drop a dragged panel just before `beforeId` (or at the end when it is null). Dropping on itself changes nothing. */
export function moveBefore(layout, id, beforeId, at) {
  if (id === beforeId) return layout
  const moving = layout.panels.find(p => p.id === id)
  if (!moving) return layout
  const rest = layout.panels.filter(p => p.id !== id)
  const i = beforeId == null ? rest.length : rest.findIndex(p => p.id === beforeId)
  if (i < 0) return layout
  const panels = [...rest.slice(0, i), moving, ...rest.slice(i)]
  return panels.every((p, k) => p === layout.panels[k]) ? layout : edit(layout, panels, at)
}

/** Replace the rail's pins. */
export const setPins = (layout, pins, at) => (pins === layout.pins ? layout : { ...layout, at: at ?? now(), pins })

/** Whether two layouts draw the same panels (the `at` and the pins aside). */
export const sameLayout = (a, b) => JSON.stringify(a.panels) === JSON.stringify(b.panels)

// Kept per account in this browser (docs "Kept on the device"); the app draws from this copy. The key ends in
// ":<pubkey>", so signing out wipes it with the rest of the account's keys (haven/vault.js accountKeys).
const KEY = "nv-space-layout"
/** This browser's copy, or the default. A copy in a newer format draws the default (normalize). */
export function readLayout(me, ids, storage = globalThis.localStorage) {
  try { return normalize(JSON.parse(storage?.getItem(`${KEY}:${me}`) ?? "null"), ids) ?? defaultLayout(ids) } catch { return defaultLayout(ids) }
}
export function writeLayout(me, layout, storage = globalThis.localStorage) {
  try { storage?.setItem(`${KEY}:${me}`, JSON.stringify(layout)) } catch {}
}
