// The Feed's Auto-load / Replies / Reposts switches (the iPhone's FeedView+ToolbarMenu and FeedFilterEngine), and which
// of the new notes a sync brings are newer than the ones shown. Kept in this browser; the iPhone's defaults: auto-load,
// replies and reposts on. Auto-load off holds the new notes behind the pill until it is tapped (Logen 2026-11-10, the
// pre-ea93264f5 behaviour); on, they go in on their own (Logen 2026-11-04).
import { replyRefs } from "./thread.js"
import { commentParent, isRepost, timelineShows } from "./feed-kinds.js"

const KEY = "nv:feed-filters"
export const FILTER_DEFAULTS = { replies: true, reposts: true, autoLoad: true }

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

/** The notes the switches let through, of the ones a timeline draws at all (timelineShows). Threaded marks the layout
 *  only: the iPhone's Replies switch still filters a threaded feed (FeedView+Layout.swift:88 — threading turns replies
 *  on rather than pinning them on, and "the Replies filter still switches them back off"). */
export function applyFilters(notes, { replies, reposts }, { threaded = false } = {}) {
  return notes.filter(n => timelineShows(n) && (reposts || !isRepost(n)) && (replies || !isReply(n)))
}

/** The switches in effect when the layout becomes `layout`: as the iPhone (FeedView+Layout.swift:88), a threaded feed
 *  with Replies off would show nothing but the roots the reader just came from, so threading turns them on. The switch
 *  itself is free to turn them back off. */
export const layoutFilters = (layout, filters) =>
  layout === "threaded" && !filters.replies ? { ...filters, replies: true } : filters

/** Notes in `fresh` newer than everything shown and not shown yet, newest first: what the pill holds. */
export function newerNotes(shown, fresh) {
  const have = new Set(shown.map(n => n.id))
  const top = shown.reduce((t, n) => Math.max(t, n.created_at), 0)
  return fresh.filter(n => !have.has(n.id) && n.created_at > top).sort((a, b) => b.created_at - a.created_at)
}
