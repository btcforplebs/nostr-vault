// The Feed's Auto-load / Replies / Reposts switches (the iPhone's FeedView+ToolbarMenu and FeedFilterEngine), and which
// of the new notes a sync brings are newer than the ones shown. Kept in this browser; the iPhone's defaults: auto-load,
// replies and reposts on. Auto-load off holds the new notes behind the pill until it is tapped (Logen 2026-11-10, the
// pre-ea93264f5 behaviour); on, they go in on their own (Logen 2026-11-04).
import { replyRefs } from "./thread.js"
import { commentParent, embedded, isRepost, repostRef, timelineShows } from "./feed-kinds.js"

const KEY = "nv:feed-filters"
export const FILTER_DEFAULTS = { replies: true, reposts: true, autoLoad: true }

// Builds before 11-04 had Auto-load off by default and saved `autoLoad: false` with any switch the reader touched, so
// that old value would hold the pill on with the switch never turned off (Logen 2026-11-11 "fix now"). Only an Auto-load
// saved by this build (marked `v`) counts; an older one reads as the default, on.
const SAVED_V = 2
export function loadFilters(storage = globalThis.localStorage) {
  let saved = {}
  try { saved = JSON.parse(storage?.getItem(KEY) ?? "{}") ?? {} } catch {}
  const out = { ...FILTER_DEFAULTS }
  for (const k of Object.keys(out)) {
    if (k === "autoLoad" && saved.v !== SAVED_V) continue
    if (typeof saved[k] === "boolean") out[k] = saved[k]
  }
  return out
}
export function saveFilters(filters, storage = globalThis.localStorage) {
  try { storage?.setItem(KEY, JSON.stringify({ ...filters, v: SAVED_V })) } catch {}
}

/** A kind 1 that answers another note (NIP-10), or a comment that answers one (NIP-22). */
export const isReply = ev => (ev?.kind === 1 && !!replyRefs(ev).parent) || !!commentParent(ev)

/** The notes the switches let through, of the ones a timeline draws at all (timelineShows). Threaded marks the layout
 *  only: the iPhone's Replies switch still filters a threaded feed (FeedView+Layout.swift:88 — threading turns replies
 *  on rather than pinning them on, and "the Replies filter still switches them back off"). */
export function applyFilters(notes, { replies, reposts }, { threaded = false } = {}) {
  return oncePerNote(notes.filter(n => timelineShows(n) && (reposts || !isRepost(n)) && (replies || !isReply(n))))
}

/** What a repost shows: the note its e tag names (else the one it embeds), or the article its a tag names; null when
 *  it names nothing. */
export function repostKey(ev) {
  const ref = repostRef(ev)
  if (ref?.type === "note") return ref.id
  if (ref?.type === "addr") return `${ref.kind}:${ref.pubkey}:${ref.d}`
  const id = embedded(ev)?.id
  return typeof id === "string" ? id : null
}

/** Each note drawn once. Two follows reposting one note, or a follow's note and someone's repost of it, drew the same
 *  card twice in one view. A repost of a note already listed goes (the note shows itself); several reposts of the
 *  same note keep the first, which is the newest in a newest-first list. The Vault applies the same rule
 *  (VaultDataProcessing.swift, Android VaultRepostDedupe). The same event listed twice draws once. `notes` keeps its
 *  order. */
export function oncePerNote(notes) {
  const listed = new Set()
  for (const n of notes) if (!isRepost(n)) { listed.add(n.id); if (n.kind === 30023) listed.add(addrOf(n)) }
  const shown = new Set(), ids = new Set()
  return notes.filter(n => {
    if (ids.has(n.id)) return false // one event twice (two merges racing): drawn once, under one key
    ids.add(n.id)
    if (!isRepost(n)) return true
    const key = repostKey(n)
    if (!key) return true
    if (listed.has(key) || shown.has(key)) return false
    shown.add(key)
    return true
  })
}
const addrOf = ev => `${ev.kind}:${ev.pubkey}:${(ev.tags ?? []).find(t => t[0] === "d")?.[1] ?? ""}`

/** The switches in effect when the reader switches the layout to `layout` (Logen, 2026-11-11): expanded starts with
 *  Replies off, so it shows single posts; threaded with them on, so it shows whole conversations. The Replies switch
 *  is still free to flip them in either layout. */
export const layoutFilters = (layout, filters) => {
  const replies = layout === "threaded"
  return filters.replies === replies ? filters : { ...filters, replies }
}

/** Notes in `fresh` newer than everything shown and not shown yet, newest first: what the pill holds. */
export function newerNotes(shown, fresh) {
  const have = new Set(shown.map(n => n.id))
  const top = shown.reduce((t, n) => Math.max(t, n.created_at), 0)
  return fresh.filter(n => !have.has(n.id) && n.created_at > top).sort((a, b) => b.created_at - a.created_at)
}
