// The feed's ceiling: a long session must not grow the DOM, the heap or the per-sync read without bound.
// 500 is ~5,000 scrolls of a phone feed and still under a second to read from Haven (41 nodes/note at 70b491cd:
// 500 notes ≈ 20,500 nodes if all were drawn, so the draw window below stays at 150).
// Two ends, two caps: notes joining at the top (a sync, a live note) push the oldest out; notes joining at the bottom
// (Older) push the newest out, because those are the ones the reader has scrolled away from. Capping the wrong end is
// what made Older throw away the page it had just read and fetch it again forever (NV_WEB_FIX_SPECS_2026_11_10 D1).
export const MAX_NOTES = 500
export const DRAW_NOTES = 150
/** How close to the bottom of what is drawn the reader has to be before another DRAW_NOTES are drawn. */
export const GROW_PX = 800

/** Newest first, at most `max`: the drop happens at the bottom, which is exactly what "Older" re-reads.
 *  `protect`: a note id the reader is on — the list holds one note past it rather than delete what is being read. */
export function capNotes(notes, max = MAX_NOTES, { protect = null } = {}) {
  if (!Array.isArray(notes) || notes.length <= max) return notes
  if (protect) {
    const i = notes.findIndex(n => n?.id === protect)
    if (i >= max) return notes.slice(0, i + 1)
  }
  return notes.slice(0, max)
}

/** The same for notes joining at the bottom ("Older"): the newest are dropped instead, so the page just fetched stays
 *  and the next `until` (`notes.at(-1)`) moves on. `protect`: the note the reader is on is never dropped either. */
export function capOlder(notes, max = MAX_NOTES, { protect = null } = {}) {
  if (!Array.isArray(notes) || notes.length <= max) return notes
  const from = notes.length - max
  if (protect) {
    const i = notes.findIndex(n => n?.id === protect)
    if (i >= 0 && i < from) return notes.slice(i)
  }
  return notes.slice(from)
}

/** What reload() may ask Haven for: never more than the ceiling, whatever the reader has loaded. */
export const readLimit = (page, have, max = MAX_NOTES) => Math.min(max, Math.max(page, have))

/**
 * The notes an update may put in front of the reader: `read`, a reload's page from Haven, and `live`, what a live
 * subscription just handed us.
 *
 * `seenTop` (the newest `created_at` this screen has ever shown) guards the reload page only: a page read after the
 * ceiling trimmed the top is newer than the list's own top and must not go back in above the reader (mergeReload).
 * A note the subscription just delivered is new to this screen whatever its `created_at`: a relay can deliver it late,
 * after a newer note from someone else already moved the top, and its author's clock can be behind — and those were
 * being dropped in silence ("the posts are not dropping in", Logen 2026-11-10; measured on nostrvault.app: a note
 * stamped 15 s back reached the page in 2 relay frames and never drawn, only after a reload).
 * Deduped by id, newest first. -> notes
 */
export function freshNotes({ read = [], live = [], seenTop = 0 } = {}) {
  const out = new Map()
  for (const n of read) if (n?.id && n.created_at > seenTop) out.set(n.id, n)
  for (const n of live) if (n?.id) out.set(n.id, n)
  return [...out.values()].sort((a, b) => b.created_at - a.created_at)
}

/**
 * `fresh` joining `list` (newest first) at its place: a note can be older than the top and still be new (see
 * freshNotes), so it is merged by `created_at` instead of always being put on top, and nothing already shown is added
 * twice. The tail gives way at the ceiling, as capNotes does; `protect`: the note the reader is on. -> notes
 */
export function insertNotes(list, fresh, { max = MAX_NOTES, protect = null } = {}) {
  const base = list ?? []
  const have = new Set(base.map(n => n.id))
  const add = (fresh ?? []).filter(n => n?.id && !have.has(n.id)).sort((a, b) => b.created_at - a.created_at)
  if (!add.length) return base
  const out = []
  let i = 0, j = 0
  while (i < add.length || j < base.length) {
    // A tie keeps the list's own order: what is already on screen never moves under the reader.
    if (j >= base.length || (i < add.length && add[i].created_at > base[j].created_at)) out.push(add[i++])
    else out.push(base[j++])
  }
  return capNotes(out, max, { protect })
}

/** What the screen draws: the window, grown as the reader nears the bottom. */
export const drawNotes = (notes, shown = DRAW_NOTES, max = MAX_NOTES) => (notes ?? []).slice(0, Math.min(shown, max))

/** The next window size after one draw: a DRAW_NOTES step, never past the ceiling. */
export const nextDraw = (drawn, total, step = DRAW_NOTES, max = MAX_NOTES) => {
  if (drawn >= total) return drawn
  return Math.min(max, total, drawn + step)
}

/**
 * What a sync reload shows, without rebuilding the list. Haven's word for the page it answered, with the note objects
 * already on screen (a row keyed by note id stays put, so nothing above the reader is redrawn); a note Haven no longer
 * has goes; and the notes "Older" read past that page stay where they are.
 *
 * `seenTop`: the newest `created_at` this screen has ever shown. Only notes newer than that may join above the list.
 * Without it, once the ceiling has trimmed the top (an Older append drops the newest), the reload's page is newer than
 * the list's top and the whole page goes back in above the reader, pushing them down the list by however many pages
 * they had scrolled past — the same jump the anchored reload exists to avoid. -> { notes, fresh, changed }
 */
export function mergeReload(list, read, { max = MAX_NOTES, protect = null, seenTop = 0 } = {}) {
  const base = list ?? []
  const held = new Map(base.map(n => [n.id, n]))
  const ids = new Set(read.map(n => n.id))
  const pageOldest = read.at(-1)?.created_at ?? 0
  const fresh = read.filter(n => n.created_at > seenTop && !held.has(n.id))
  const out = base.some(n => n.created_at < pageOldest)
    ? [...fresh, ...base.filter(n => n.created_at < pageOldest || ids.has(n.id))]
    : read.map(n => held.get(n.id) ?? n)
  const changed = !(out.length === base.length && out.every((n, i) => n.id === base[i].id))
  if (!changed) return { notes: base, fresh, changed }
  // Which end gives way: the one the reader is furthest from. Reading down the list that is the oldest (capNotes);
  // sitting at the bottom of it, the newest the ceiling already dropped (capOlder), so the note under the reader's
  // thumb is never the one that goes (NV_WEB_FIX_SPECS_2026_11_10 check 6).
  const i = protect == null ? -1 : out.findIndex(n => n?.id === protect)
  const kept = i >= 0 && i > out.length / 2 ? capOlder(out, max, { protect }) : capNotes(out, max, { protect })
  return { notes: kept, fresh, changed }
}
