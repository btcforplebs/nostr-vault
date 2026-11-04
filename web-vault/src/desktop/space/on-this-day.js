// The On this day panel's rules (no styles, so tests can import it): the user's own notes from today's date one and two
// years ago, read from their own vault (Haven's outbox), never from a relay. Replies stay out: what is shown is what
// the user posted, not their side of someone else's thread. Nothing here publishes.
import { isReply } from "../../net/feed-filters.js"
import { previewOf, imagesOf } from "../../net/vault-lists.js"

/** How many years back the panel looks. */
export const YEARS_BACK = [1, 2]
/** Notes drawn per year at most (the oldest of the day first, as the day went). */
export const PER_YEAR = 3

/**
 * Today's date `years` back, as a local day: { years, since, until } in unix seconds, `until` the first second of the
 * next day. null when that date did not exist that year (29 February in a non-leap year).
 */
export function dayWindow(now, years) {
  const d = new Date(now)
  const start = new Date(d.getFullYear() - years, d.getMonth(), d.getDate())
  if (start.getMonth() !== d.getMonth()) return null
  const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1)
  return { years, since: Math.floor(start.getTime() / 1000), until: Math.floor(end.getTime() / 1000) }
}

/** The windows for every year the panel looks back, skipping dates that did not exist. */
export const dayWindows = (now = Date.now(), years = YEARS_BACK) => years.map(y => dayWindow(now, y)).filter(Boolean)

/** A key that changes at local midnight, so the panel reads again on a new day. */
export const dayKey = (now = Date.now()) => { const d = new Date(now); return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}` }

/** The user's own top-level kind 1 notes inside the window, oldest first, at most `max`, each id once. */
export function notesOnDay(evs, me, w, max = PER_YEAR) {
  const seen = new Set()
  return evs
    .filter(e => e && e.kind === 1 && e.pubkey === me && e.created_at >= w.since && e.created_at < w.until && !isReply(e))
    .filter(e => !seen.has(e.id) && seen.add(e.id))
    .sort((a, b) => a.created_at - b.created_at)
    .slice(0, max)
}

/** The relay filter for one window, for the user's own vault. */
export const dayFilter = (me, w) => ({ kinds: [1], authors: [me], since: w.since, until: w.until - 1, limit: 100 })

/** "1 year ago", "2 years ago". */
export const yearsText = n => (n === 1 ? "1 year ago" : `${n} years ago`)

/** One line for a note: its text without picture links, or "Photo" / "Photos" when that is all it has. */
export function lineText(ev) {
  const text = previewOf(ev).trim()
  if (text) return text
  const n = imagesOf(ev).length
  return n > 1 ? "Photos" : n ? "Photo" : "Note"
}

/** Reads every window from the vault's outbox -> [{ years, since, notes }] in YEARS_BACK order. */
export async function readOnThisDay(vault, me, now = Date.now()) {
  return Promise.all(dayWindows(now).map(async w => {
    const evs = await vault.outbox.query(dayFilter(me, w)).catch(() => [])
    return { years: w.years, since: w.since, notes: notesOnDay(evs, me, w) }
  }))
}
