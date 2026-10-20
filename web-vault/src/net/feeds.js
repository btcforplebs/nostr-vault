// The Feed's picker: Following (Haven /feed, see sync.js), Global (recent notes from the user's read relays),
// Hashtag (`#t` notes), Popular (net/popular.js) and Media (Following's image and video notes, net/media.js). Global and Hashtag notes are strangers': they are held in memory only and never written
// to Haven /feed, which is the Following feed's store. Their names and pictures, and the quotes and @names inside
// their notes, stay in memory too: FeedScreen passes `memoryOnly` to their cards and `save: false` to fetchProfiles.
import { pool, uniq } from "./pool.js"
import { FEED_KINDS } from "./sync.js"

// The iPhone's FeedMode order (Services/FeedServiceTypes.swift FeedMode). Readers (src/readers) take their place in it.
export const FEED_ORDER = ["following", "discovery", "global", "hashtag", "popular", "media", "reels", "articles", "recipes",
  "marketplace", "live", "polls", "music"]
export const FEEDS = [
  { id: "following", label: "Following" },
  { id: "global", label: "Global" },
  { id: "hashtag", label: "Hashtag" },
  { id: "popular", label: "Popular" },
  { id: "media", label: "Media" },
]
/** The picker's feeds: these, plus each reader's { id, label }, in the iPhone's order. */
export function feedList(readers = []) {
  const all = [...FEEDS, ...readers.map(r => ({ id: r.id, label: r.label }))]
  const at = id => { const i = FEED_ORDER.indexOf(id); return i < 0 ? FEED_ORDER.length : i }
  return all.sort((a, b) => at(a.id) - at(b.id))
}
/** Following and Media are read from Haven /feed; the others are strangers' notes, held in memory. */
export const fromHaven = mode => mode === "following" || mode === "media"
const KEY = "nv-feed"

/** The last feed picked on this browser: { mode, tag }. Following when nothing (or nothing valid) is saved. */
export function loadChoice(storage = globalThis.localStorage, feeds = FEEDS) {
  try {
    const c = JSON.parse(storage?.getItem(KEY) ?? "null")
    const mode = feeds.some(f => f.id === c?.mode) ? c.mode : "following"
    return { mode, tag: normalizeTag(c?.tag) }
  } catch { return { mode: "following", tag: "" } }
}

export function saveChoice(choice, storage = globalThis.localStorage) {
  storage?.setItem(KEY, JSON.stringify({ mode: choice.mode, tag: normalizeTag(choice.tag) }))
}

/** What the hashtag box holds, as a `#t` value: no leading #, lowercased (clients tag lowercase), one word. */
export function normalizeTag(text) {
  const t = String(text ?? "").trim().replace(/^#+/, "").toLowerCase()
  return t && !/\s/.test(t) ? t : ""
}

/** The feed a #tag link asks for ("#/feed?tag=bitcoin", NoteText), or null when the address names no tag. */
export function tagChoice(hash = "") {
  const i = hash.indexOf("?")
  const tag = normalizeTag(new URLSearchParams(i < 0 ? "" : hash.slice(i + 1)).get("tag"))
  return tag ? { mode: "hashtag", tag } : null
}

/** The relay filter for a stranger feed, or null when there is nothing to ask for (Hashtag with no tag). */
export function feedFilter({ mode, tag }, { limit = 100, until } = {}) {
  const page = { limit, ...(until ? { until } : {}) }
  if (mode === "global") return { kinds: FEED_KINDS, ...page }
  if (mode === "hashtag") return tag ? { kinds: [1], "#t": [tag], ...page } : null
  return null
}

/** One page of a stranger feed from the network, newest first, once each. Nothing is stored. `query` is for tests. */
export async function fetchStrangerFeed(choice, relays, { limit = 100, until, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const filter = feedFilter(choice, { limit, until })
  if (!filter) return []
  const evs = await query(uniq(relays), filter, { maxWait: 8000 })
  const byId = new Map()
  for (const ev of evs) if (ev?.id && filter.kinds.includes(ev.kind) && !byId.has(ev.id)) byId.set(ev.id, ev)
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at)
}

/** Add a page to what is shown, dropping notes already there. */
export function mergePage(have, more) {
  const ids = new Set(have.map(e => e.id))
  return [...have, ...more.filter(e => !ids.has(e.id))]
}

/** A status setter for work starting now: it goes quiet once `seq` (FeedScreen's feed counter) moves on, so a
 *  Following sync or a Global page still running after a switch can't write onto the next feed's status line. */
export function statusGate(seq, set) {
  const n = seq.current
  return text => { if (n === seq.current) set(text) }
}

/** Everyone a page of notes shows: authors, and the author inside each repost. */
export function noteAuthors(notes) {
  return notes.flatMap(n => { if (n.kind !== 6) return [n.pubkey]; try { return [n.pubkey, JSON.parse(n.content).pubkey] } catch { return [n.pubkey] } }).filter(Boolean)
}

// Stranger feeds already loaded this session, by feed, so switching back shows them at once. Memory only.
const held = new Map()
export const feedKey = ({ mode, tag }) => (mode === "hashtag" ? `hashtag:${tag}` : mode)
export const heldNotes = choice => held.get(feedKey(choice)) ?? null
export const holdNotes = (choice, notes) => { held.set(feedKey(choice), notes) }
