// The Feed's picker: Following (Haven /feed, see sync.js), Discover (your extended network's notes, net/discover.js), Global (recent notes from the user's read relays),
// Hashtag (`#t` notes), Popular (net/popular.js) and Media (Following's image and video notes, net/media.js). Discover, Global and Hashtag notes are strangers': they are held in memory only and never written
// to Haven /feed, which is the Following feed's store. Their names and pictures, and the quotes and @names inside
// their notes, stay in memory too: FeedScreen passes `memoryOnly` to their cards and `save: false` to fetchProfiles.
import { pool, uniq } from "./pool.js"
import { FEED_KINDS } from "./sync.js"
import { filterGlobal } from "./global-trust.js"
import { trustedFilters } from "../readers/trust.js"

// The iPhone's FeedMode order (Services/FeedServiceTypes.swift FeedMode). Readers (src/readers) take their place in it.
export const FEED_ORDER = ["following", "discovery", "global", "hashtag", "popular", "media", "reels", "articles", "recipes",
  "marketplace", "live", "polls", "music"]
export const FEEDS = [
  { id: "following", label: "Following" },
  { id: "discovery", label: "Discover" },
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
// Edit Feeds (iPhone FeedMenuEditor, Models/FeedLayoutMode.swift FeedMenuOrder): the picker's order and the feeds it
// hides, saved on this browser. Following is the home feed, so it is always shown.
const MENU_KEY = "nv-feed-menu"
export const PINNED_FEED = "following"

/** `stored` ids in their saved order, dropping ones no longer offered; a feed the saved order doesn't know (added in a
 *  later version) goes in after the feed that comes before it by default, as FeedMenuOrder.ordered does. */
export function menuOrder(stored, defaults) {
  const out = [...new Set(stored)].filter(id => defaults.includes(id))
  defaults.forEach((id, i) => {
    if (out.includes(id)) return
    const before = defaults.slice(0, i).findLast(d => out.includes(d))
    out.splice(before ? out.indexOf(before) + 1 : 0, 0, id)
  })
  return out
}

/** The saved { order, hidden }: lists of feed ids, empty when nothing (or junk) is saved. */
export function loadMenu(storage = globalThis.localStorage) {
  try {
    const m = JSON.parse(storage?.getItem(MENU_KEY) ?? "null")
    const ids = v => (Array.isArray(v) ? v.filter(x => typeof x === "string") : [])
    return { order: ids(m?.order), hidden: ids(m?.hidden) }
  } catch { return { order: [], hidden: [] } }
}

/** Saves the menu; the default order and nothing hidden is saved as nothing, so later feeds keep their default place. */
export function saveMenu({ order, hidden }, feeds, storage = globalThis.localStorage) {
  const defaults = feeds.map(f => f.id)
  const ordered = menuOrder(order, defaults)
  const hide = ordered.filter(id => id !== PINNED_FEED && hidden.includes(id))
  const same = ordered.every((id, i) => id === defaults[i])
  if (same && !hide.length) return storage?.removeItem(MENU_KEY)
  storage?.setItem(MENU_KEY, JSON.stringify({ order: same ? [] : ordered, hidden: hide }))
}

/** Every feed in the menu's order, each with `shown`. */
export function menuFeeds(feeds, menu) {
  const byId = new Map(feeds.map(f => [f.id, f]))
  return menuOrder(menu.order, feeds.map(f => f.id))
    .map(id => ({ ...byId.get(id), shown: id === PINNED_FEED || !menu.hidden.includes(id) }))
}

/** Moves the item at `from` to `to` in a copy of `list`. */
export const moveItem = (list, from, to) => {
  const out = [...list]
  out.splice(to, 0, ...out.splice(from, 1))
  return out
}

/** The feeds the picker lists: shown ones, in the menu's order. */
export const visibleFeeds = (feeds, menu) => menuFeeds(feeds, menu).filter(f => f.shown).map(({ shown, ...f }) => f)

/** Following and Media are read from Haven /feed; the others are strangers' notes, held in memory. */
export const fromHaven = mode => mode === "following" || mode === "media"

// Media's Following / Global choice, as on the iPhone (FeedService.mediaFeedMode, FeedView+Toolbar.swift): Following is
// the follows' notes from Haven /feed; Global is Global's notes (trust-screened, held in memory), as a grid. Kept on
// this browser apart from the picked feed, so picking Media again opens the same one.
const SCOPE_KEY = "nv-media-scope"
export const loadMediaScope = (storage = globalThis.localStorage) => (storage?.getItem(SCOPE_KEY) === "global" ? "global" : "following")
export const saveMediaScope = (scope, storage = globalThis.localStorage) => storage?.setItem(SCOPE_KEY, scope === "global" ? "global" : "following")
/** The choice with Media's scope filled in (the saved one when it has none); other feeds as they are. */
export const withScope = (choice, storage = globalThis.localStorage) =>
  choice.mode === "media" ? { ...choice, scope: choice.scope === "global" || choice.scope === "following" ? choice.scope : loadMediaScope(storage) } : choice
/** Whether a choice is read from Haven /feed: Following, and Media on Following. */
export const readsHaven = choice => choice.mode === "following" || (choice.mode === "media" && choice.scope !== "global")
/** Global, and Media on Global: read from everyone, kept to the web of trust (global-trust.js). */
export const globalLike = choice => choice.mode === "global" || (choice.mode === "media" && choice.scope === "global")
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
export function feedFilter({ mode, tag, scope }, { limit = 100, until } = {}) {
  const page = { limit, ...(until ? { until } : {}) }
  if (mode === "global" || (mode === "media" && scope === "global")) return { kinds: FEED_KINDS, ...page }
  if (mode === "hashtag") return tag ? { kinds: [1], "#t": [tag], ...page } : null
  return null
}

/** One page of a stranger feed from the network, newest first, once each. Nothing is stored. Global takes `trust`
 *  (readers/trust.js globalTrust): it asks once for trusted authors and once open, as the iPhone does, and keeps only
 *  what Global shows (global-trust.js); no trust shows nothing. `query` is for tests. */
export async function fetchStrangerFeed(choice, relays, { limit = 100, until, trust = null, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const filter = feedFilter(choice, { limit, until })
  if (!filter) return []
  const global = globalLike(choice)
  if (global && !trust?.size) return []
  const filters = global ? trustedFilters(filter, trust) : [filter]
  const evs = (await Promise.all(filters.map(f => query(uniq(relays), f, { maxWait: 8000 })))).flat()
  const byId = new Map()
  for (const ev of evs) if (ev?.id && filter.kinds.includes(ev.kind) && !byId.has(ev.id)) byId.set(ev.id, ev)
  const notes = [...byId.values()].sort((a, b) => b.created_at - a.created_at)
  return global ? filterGlobal(notes, trust) : notes
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

/** Everyone a page of notes shows: authors, and the author inside each repost (a bare repost names them in its p tag). */
export function noteAuthors(notes) {
  return notes.flatMap(n => {
    if (n.kind !== 6 && n.kind !== 16) return [n.pubkey]
    let inner
    try { inner = JSON.parse(n.content)?.pubkey } catch {}
    return [n.pubkey, inner ?? (n.tags ?? []).find(t => t[0] === "p")?.[1]]
  }).filter(pk => /^[0-9a-f]{64}$/.test(pk ?? ""))
}

// Stranger feeds already loaded this session, by feed, so switching back shows them at once. Memory only.
const held = new Map()
export const feedKey = ({ mode, tag, scope }) => (mode === "hashtag" ? `hashtag:${tag}` : mode === "media" && scope === "global" ? "media:global" : mode)
export const heldNotes = choice => held.get(feedKey(choice)) ?? null
export const holdNotes = (choice, notes) => { held.set(feedKey(choice), notes) }
