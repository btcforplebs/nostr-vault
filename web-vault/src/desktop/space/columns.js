// The two side columns of the desktop layout (plan NV_WEB_ONE_PLAN.md step 3): the left one under the menu and the
// right one, Your space. Both draw cards from the same saved layout (space-layout.js): its `panels` list holds every
// card, ours and the apps', in one order, and each entry says which column it is in. Pure, so tests load it.
//
// A card entry: { id, on, open, side?, size? }
//   id:   one of our panels (panel-ids.js) or "napplet:<publisher hex>:<d>" (an installed app, catalog.js nappletLine)
//   side: "left" or missing (missing = right, so a layout from before this step reads as it did)
//   size: "S" | "M" | "L", or missing (ours: their own height, as today; an app: M)
// Kept in this browser only, per account (layout-store.js), like the rest of the layout.

export const LEFT = "left", RIGHT = "right"
export const SIZES = ["S", "M", "L"]
/** Card heights in px (plan §3: S 160 / M 320 / L 560). */
export const SIZE_PX = { S: 160, M: 320, L: 560 }
/** At most this many app frames run at once (each is a walled-off page of its own). */
export const MAX_FRAMES = 8

const APP = "napplet:"
export const appCardId = line => `${APP}${line}`
export const isAppCard = id => typeof id === "string" && id.startsWith(APP)
/** "napplet:<pub>:<d>" -> "<pub>:<d>" (a d tag may hold colons). */
export const lineOfCard = id => (isAppCard(id) ? id.slice(APP.length) : null)

export const sideOf = p => (p?.side === LEFT ? LEFT : RIGHT)
const now = () => Math.floor(Date.now() / 1000)
const edit = (layout, panels, at) => ({ ...layout, at: at ?? now(), panels })

/** The cards to draw in `side`, in order: shown, and drawable (`canDraw(id)`: ours, or an app still installed). */
export const columnCards = (layout, side, canDraw) => layout.panels.filter(p => p.on && sideOf(p) === side && canDraw(p.id))

/**
 * Move a drawn card one place up (-1) or down (+1) within its column. Hidden, unknown and other-column entries keep
 * their places. At the top or bottom nothing changes.
 */
export function moveInColumn(layout, id, delta, canDraw, at) {
  const card = layout.panels.find(p => p.id === id)
  if (!card) return layout
  const drawn = columnCards(layout, sideOf(card), canDraw).map(p => p.id)
  const i = drawn.indexOf(id), j = i + delta
  if (i < 0 || j < 0 || j >= drawn.length) return layout
  const a = layout.panels.findIndex(p => p.id === id), b = layout.panels.findIndex(p => p.id === drawn[j])
  const panels = [...layout.panels]
  ;[panels[a], panels[b]] = [panels[b], panels[a]]
  return edit(layout, panels, at)
}

/** Put `id` in `side`, just before `beforeId` (a card of that column) or at its end when beforeId is null. A drop on
 *  itself, or where it already is, changes nothing. */
export function dropCard(layout, id, side, beforeId = null, at) {
  if (id === beforeId) return layout
  const card = layout.panels.find(p => p.id === id)
  if (!card) return layout
  const moved = withSide(card, side)
  const rest = layout.panels.filter(p => p.id !== id)
  let i
  if (beforeId == null) {
    // After the last entry of that column (or at the very end when it has none), so it lands at the bottom of it.
    const last = rest.map(sideOf).lastIndexOf(side)
    i = last < 0 ? rest.length : last + 1
  } else {
    i = rest.findIndex(p => p.id === beforeId)
    if (i < 0) return layout
  }
  const panels = [...rest.slice(0, i), moved, ...rest.slice(i)]
  return panels.every((p, k) => p === layout.panels[k] || JSON.stringify(p) === JSON.stringify(layout.panels[k])) ? layout : edit(layout, panels, at)
}

/** The other column's end: the "Move to the other side" button. */
export const moveAcross = (layout, id, at) => {
  const card = layout.panels.find(p => p.id === id)
  return card ? dropCard(layout, id, sideOf(card) === LEFT ? RIGHT : LEFT, null, at) : layout
}

function withSide(card, side) {
  const { side: _, ...rest } = card
  return side === LEFT ? { ...rest, side: LEFT } : rest
}

/** A card's size; null takes it back to its own (ours) or M (an app). */
export function setSize(layout, id, size, at) {
  if (size != null && !SIZES.includes(size)) return layout
  const card = layout.panels.find(p => p.id === id)
  if (!card || (card.size ?? null) === size) return layout
  return edit(layout, layout.panels.map(p => {
    if (p.id !== id) return p
    const { size: _, ...rest } = p
    return size == null ? rest : { ...rest, size }
  }), at)
}

/**
 * Add a card to `side` (the + Add sheet). One of ours taken off comes back in its old place when it was in that column,
 * else at that column's end. An app card goes at the column's end, size M, open.
 */
export function addCard(layout, id, side, at) {
  const had = layout.panels.find(p => p.id === id)
  if (had?.on && sideOf(had) === side) return layout
  if (had && sideOf(had) === side) return edit(layout, layout.panels.map(p => (p.id === id ? { ...p, on: true } : p)), at)
  const card = had ? withSide({ ...had, on: true }, side) : withSide({ id, on: true, open: true, ...(isAppCard(id) ? { size: "M" } : {}) }, side)
  const rest = layout.panels.filter(p => p.id !== id)
  const last = rest.map(sideOf).lastIndexOf(side)
  const i = last < 0 ? rest.length : last + 1
  return edit(layout, [...rest.slice(0, i), card, ...rest.slice(i)], at)
}

/** Take a card off. Ours stays in the list, off (so it comes back where it was); an app's entry goes (the app stays
 *  installed and is in + Add). */
export function takeOff(layout, id, at) {
  if (!layout.panels.some(p => p.id === id)) return layout
  return isAppCard(id)
    ? edit(layout, layout.panels.filter(p => p.id !== id), at)
    : edit(layout, layout.panels.map(p => (p.id === id ? { ...p, on: false } : p)), at)
}

/** An app removed (Remove app): every card of it goes, and none comes back if it is installed again. */
export function dropApp(layout, line, at) {
  const id = appCardId(line)
  return layout.panels.some(p => p.id === id) ? edit(layout, layout.panels.filter(p => p.id !== id), at) : layout
}

/** Reset to the default: our panels, in order, on the right, shown and open; no app cards; the left column empty. */
export const resetColumns = (layout, ids, at) => edit(layout, ids.map(id => ({ id, on: true, open: true })), at)
/** Whether the layout's cards are the default ones (the pins aside). */
export const isDefaultColumns = (layout, ids) => JSON.stringify(layout.panels) === JSON.stringify(ids.map(id => ({ id, on: true, open: true })))

/**
 * What a manifest says about drawing as a card: ["surface", "widget", ...sizes]. A widget lists the sizes it draws
 * (none listed: all three); any other app can still go in a column, as a panel, at M or L (plan §2).
 */
export function surfaceOf(event) {
  const t = (event?.tags ?? []).find(x => Array.isArray(x) && x[0] === "surface" && x[1] === "widget")
  if (!t) return { widget: false, sizes: ["M", "L"] }
  const sizes = SIZES.filter(s => t.slice(2).includes(s))
  return { widget: true, sizes: sizes.length ? sizes : [...SIZES] }
}

/** The size an app card draws at: its saved one when the app offers it, else the nearest it does (M first). */
export function appSize(saved, sizes) {
  if (sizes.includes(saved)) return saved
  return sizes.includes("M") ? "M" : sizes.at(-1)
}

/**
 * The + Add sheet's three groups (plan §1: ours and other people's):
 *   ours:      our panels not shown in either column, in their default order
 *   installed: apps this account installed that have no card yet, widgets first
 *   catalog:   apps on the user's relays it hasn't installed, that can run here
 * `installed` is catalog.js appStore list(); `catalog` catalogEntries(); `manifestOf(event)` parseManifest.
 */
export function addGroups({ layout, ids, installed = [], catalog = [], manifestOf }) {
  const on = new Set(layout.panels.filter(p => p.on).map(p => p.id))
  const ours = ids.filter(id => !on.has(id))
  const mine = new Set(installed.map(a => a.line))
  const apps = installed.filter(a => !on.has(appCardId(a.line))).map(a => ({ ...a, manifest: manifestOf(a.event), surface: surfaceOf(a.event) }))
  apps.sort((a, b) => Number(b.surface.widget) - Number(a.surface.widget))
  const others = catalog.filter(e => !mine.has(e.line) && e.runs).map(e => ({ ...e, surface: surfaceOf(e.event) }))
  others.sort((a, b) => Number(b.surface.widget) - Number(a.surface.widget))
  return { ours, installed: apps, catalog: others }
}
