// "Your space"'s layout (Logen, 2026-11-03: editable): which panels show, in what order, and which are collapsed to
// their header. No styles, so tests can import it. SpaceDock.jsx draws it; panels.js names the panels there are.
//
// The saved shape is the one a later sync puts in the user's own vault (one NIP-78 app-data event, kind 30078, `d`
// SYNC_D, the JSON NIP-44 encrypted to self, the way the wallet backup is kept), so the iPad and the web can share it:
//   { v: 1, at: <unix seconds of the last edit>, panels: [{ id, on, open }, ...] }
// The array's order is the order on screen. `at` lets the newest edit win between devices. A panel id this app does
// not know (from a newer app) is kept where it is, so it survives a round trip, and is not drawn. A panel this app has
// that the layout does not name (added after the layout was saved) goes in at its place in panels.js, shown.

export const LAYOUT_V = 1
/** The NIP-78 `d` the synced layout will use. */
export const SYNC_D = "nostr-vault-space-layout"

/** The layout before any edit: every panel, in panels.js's order, shown and open. */
export const defaultLayout = (ids, at = 0) => ({ v: LAYOUT_V, at, panels: ids.map(id => ({ id, on: true, open: true })) })

/**
 * Any saved value -> a clean layout against the panel ids this app has. Bad entries and repeats drop out; unknown ids
 * stay; missing known ids go in after the known panel that comes before them in `ids` (at the top when none does).
 */
export function normalize(saved, ids) {
  if (!saved || typeof saved !== "object" || !Array.isArray(saved.panels)) return defaultLayout(ids)
  const seen = new Set(), panels = []
  for (const p of saved.panels) {
    if (!p || typeof p.id !== "string" || !p.id || seen.has(p.id)) continue
    seen.add(p.id)
    panels.push({ id: p.id, on: p.on !== false, open: p.open !== false })
  }
  ids.forEach((id, i) => {
    if (seen.has(id)) return
    seen.add(id)
    const before = ids.slice(0, i).reverse().find(b => panels.some(p => p.id === b))
    const at = before ? panels.findIndex(p => p.id === before) + 1 : 0
    panels.splice(at, 0, { id, on: true, open: true })
  })
  return { v: LAYOUT_V, at: Number.isFinite(saved.at) ? saved.at : 0, panels }
}

const now = () => Math.floor(Date.now() / 1000)
const edit = (layout, panels, at) => ({ ...layout, at: at ?? now(), panels })

/** The panels to draw, in order: shown and known. */
export const shownPanels = (layout, ids) => layout.panels.filter(p => p.on && ids.includes(p.id))
/** The known panels taken off, for "+ add", in panels.js's order. */
export const hiddenPanels = (layout, ids) => ids.filter(id => layout.panels.some(p => p.id === id && !p.on))

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

/** Whether two layouts draw the same (the `at` aside). */
export const sameLayout = (a, b) => JSON.stringify(a.panels) === JSON.stringify(b.panels)

// Kept per account in this browser until the sync lands. The key ends in ":<pubkey>", so signing out wipes it with
// the rest of the account's keys (haven/vault.js accountKeys).
const KEY = "nv-space-layout"
export function readLayout(me, ids, storage = globalThis.localStorage) {
  try { return normalize(JSON.parse(storage?.getItem(`${KEY}:${me}`) ?? "null"), ids) } catch { return defaultLayout(ids) }
}
export function writeLayout(me, layout, storage = globalThis.localStorage) {
  try { storage?.setItem(`${KEY}:${me}`, JSON.stringify(layout)) } catch {}
}
