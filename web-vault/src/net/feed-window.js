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
