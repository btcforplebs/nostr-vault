// The Feed's Replies / Reposts / Auto-load switches (the iPhone's FeedView+ToolbarMenu and FeedFilterEngine), and the
// new notes a background sync holds back behind the "N New Posts" pill (FeedView+Toolbar newPostsButton). Kept in
// this browser; the iPhone's defaults: replies and reposts on, auto-load off.
import { replyRefs } from "./thread.js"
import { commentParent, isRepost, timelineShows } from "./feed-kinds.js"

const KEY = "nv:feed-filters"
export const FILTER_DEFAULTS = { replies: true, reposts: true, autoLoad: false }

export function loadFilters(storage = globalThis.localStorage) {
  let saved = {}
  try { saved = JSON.parse(storage?.getItem(KEY) ?? "{}") ?? {} } catch {}
  const out = { ...FILTER_DEFAULTS }
  for (const k of Object.keys(out)) if (typeof saved[k] === "boolean") out[k] = saved[k]
  return out
}
export function saveFilters(filters, storage = globalThis.localStorage) {
  try { storage?.setItem(KEY, JSON.stringify(filters)) } catch {}
}

/** A kind 1 that answers another note (NIP-10), or a comment that answers one (NIP-22). */
export const isReply = ev => (ev?.kind === 1 && !!replyRefs(ev).parent) || !!commentParent(ev)

/** The notes the switches let through, of the ones a timeline draws at all (timelineShows). Threaded keeps replies
 *  whatever the switch says: they are what it groups. */
export function applyFilters(notes, { replies, reposts }, { threaded = false } = {}) {
  return notes.filter(n => timelineShows(n) && (reposts || !isRepost(n)) && (replies || threaded || !isReply(n)))
}

/** Notes in `fresh` newer than everything shown and not shown yet, newest first: what the pill holds. */
export function newerNotes(shown, fresh) {
  const have = new Set(shown.map(n => n.id))
  const top = shown.reduce((t, n) => Math.max(t, n.created_at), 0)
  return fresh.filter(n => !have.has(n.id) && n.created_at > top).sort((a, b) => b.created_at - a.created_at)
}
