// Search: NIP-50 `search` filters against the search relays. A pasted npub / nprofile / hex pubkey is not searched:
// it names one profile, so it goes straight there; a pasted note1 / nevent opens that note. The rest mirrors the
// iPhone's Search tab (Views/Search): the who/when filter, the Hashtags and Links pulled from matching notes, and the
// Recent list. Read-only; nothing here signs.
import { decode } from "nostr-tools/nip19"
import { pool } from "./pool.js"

// relay.nostr.band answered no NIP-50 query on 2026-10-13 and held each one to the timeout; of five probed, only
// search.nos.today returned results.
export const SEARCH_RELAYS = ["wss://search.nos.today"]

/** What the box holds: nothing, one profile (with any relay hints), or text to search for. */
export function parseQuery(input) {
  const q = String(input ?? "").trim()
  if (!q) return { type: "empty" }
  const ref = q.replace(/^nostr:/i, "")
  if (/^[0-9a-f]{64}$/i.test(ref)) return { type: "profile", pubkey: ref.toLowerCase(), relays: [] }
  if (/^(npub|nprofile|note|nevent)1[02-9ac-hj-np-z]+$/i.test(ref)) {
    try {
      const { type, data } = decode(ref.toLowerCase())
      if (type === "npub") return { type: "profile", pubkey: data, relays: [] }
      if (type === "nprofile") return { type: "profile", pubkey: data.pubkey, relays: data.relays ?? [] }
      if (type === "note") return { type: "note", id: data, relays: [] }
      if (type === "nevent") return { type: "note", id: data.id, relays: data.relays ?? [] }
    } catch {}
  }
  return { type: "search", text: q }
}

/** "#bitcoin" on its own names a hashtag feed (Return opens it, as on the Mac); -> "bitcoin", or null. */
export function hashtagOf(input) {
  const m = /^#([^\s#]{2,})$/.exec(String(input ?? "").trim())
  return m ? m[1].toLowerCase() : null
}

/** The live search waits for 2 characters, as the iPhone's does. */
export const MIN_QUERY = 2

/** Who / When: narrows what came back, never re-asks the relays (SearchFilter.swift). */
export const WHO = [
  { id: "everyone", label: "Everyone" },
  { id: "follows", label: "People you follow" },
  { id: "you", label: "You" },
]
export const WHEN = [
  { id: "any", label: "Any time", window: 0 },
  { id: "day", label: "Last 24 hours", window: 86400 },
  { id: "week", label: "Last week", window: 7 * 86400 },
  { id: "month", label: "Last month", window: 30 * 86400 },
]
export const NO_FILTER = { who: "everyone", when: "any" }

/** "People you follow · Last week", or null when nothing is filtered. */
export function filterCaption(f) {
  const parts = []
  if (f.who !== "everyone") parts.push(WHO.find(w => w.id === f.who)?.label)
  if (f.when !== "any") parts.push(WHEN.find(w => w.id === f.when)?.label)
  return parts.length ? parts.join(" · ") : null
}

/** Own first, then the people you follow, then everyone; the order inside each group is kept. */
function rank(list, pubkeyOf, me, follows) {
  const tier = pk => (pk === me ? 0 : follows.has(pk) ? 1 : 2)
  return list.map((x, i) => [x, i]).sort((a, b) => tier(pubkeyOf(a[0])) - tier(pubkeyOf(b[0])) || a[1] - b[1]).map(([x]) => x)
}

/** What the search relays answered, through the who/when filter and ranked own -> follows -> everyone, with the
 *  Hashtags and Links found in the notes that survived (so they follow the filter too).
 *  -> { people: [pubkey], notes: [event], hashtags: [tag], links: [{ url, title, noteId }] } */
export function shapeResults({ people, notes }, query, { me, follows = [], filter = NO_FILTER, now = Date.now() / 1000 }) {
  const fset = new Set(follows)
  const allows = pk => filter.who === "you" ? pk === me : filter.who === "follows" ? fset.has(pk) : true
  const window = WHEN.find(w => w.id === filter.when)?.window
  const shownPeople = rank(people.filter(allows), pk => pk, me, fset)
  const shownNotes = rank(notes.filter(n => allows(n.pubkey) && (!window || n.created_at >= now - window)), n => n.pubkey, me, fset)
  return { people: shownPeople, notes: shownNotes, hashtags: hashtagsIn(shownNotes, query), links: linksIn(shownNotes) }
}

/** Hashtags written in the notes whose name contains the query, lowercased, A-Z. */
export function hashtagsIn(notes, query) {
  const q = String(query ?? "").trim().toLowerCase().replace(/^#/, "")
  const found = new Set()
  for (const n of notes) for (const m of String(n.content ?? "").matchAll(/#([\p{L}\p{N}_]+)/gu)) {
    const tag = m[1].toLowerCase()
    if (tag.includes(q)) found.add(tag)
  }
  return [...found].sort()
}

/** Each link in the notes once, titled without its scheme, with the note it came from. */
export function linksIn(notes) {
  const seen = new Set(), links = []
  for (const n of notes) for (const [url] of String(n.content ?? "").matchAll(/https?:\/\/[^\s]+/g)) {
    if (seen.has(url)) continue
    seen.add(url)
    links.push({ url, title: url.replace(/^https?:\/\//, ""), noteId: n.id })
  }
  return links
}

/** The Recent list: 8 at most, newest first, one per query whatever its case, 2 characters or more. */
export const RECENT_KEY = "nv.search.recent"
export function loadRecent(storage) {
  try { const v = JSON.parse(storage?.getItem(RECENT_KEY) ?? "[]"); return Array.isArray(v) ? v.filter(x => typeof x === "string") : [] } catch { return [] }
}
export function saveRecent(storage, query) {
  const q = String(query ?? "").trim()
  const list = loadRecent(storage)
  if (q.length < MIN_QUERY) return list
  const next = [q, ...list.filter(x => x.toLowerCase() !== q.toLowerCase())].slice(0, 8)
  try { storage?.setItem(RECENT_KEY, JSON.stringify(next)) } catch {}
  return next
}
export function clearRecent(storage) { try { storage?.removeItem(RECENT_KEY) } catch {} return [] }

/** Trending: the 8 `t` tags used most in the notes on hand (the feed), most used first. */
export function trendingTags(notes) {
  const counts = new Map()
  for (const n of notes) for (const t of n.tags ?? []) if (t[0] === "t" && t[1]) {
    const tag = t[1].toLowerCase()
    counts.set(tag, (counts.get(tag) ?? 0) + 1)
  }
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([tag]) => tag)
}

/** Active in your feed: the 6 people other than you who posted most in the notes on hand, most first. */
export function activePosters(notes, me, blocked = new Set()) {
  const counts = new Map()
  for (const n of notes) if (n.pubkey !== me && !blocked.has(n.pubkey)) counts.set(n.pubkey, (counts.get(n.pubkey) ?? 0) + 1)
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([pk]) => pk)
}

/** Kind 0 results, one per pubkey (newest wins), in the order the relays ranked them. */
export function dedupePeople(events) {
  const best = new Map()
  for (const ev of events) {
    if (ev?.kind !== 0) continue
    const have = best.get(ev.pubkey)
    if (!have || ev.created_at > have.created_at) best.set(ev.pubkey, ev)
  }
  return [...best.values()]
}

/** Kind 1 results, one per id, newest first. */
export function sortNotes(events) {
  const byId = new Map(events.filter(ev => ev?.kind === 1).map(ev => [ev.id, ev]))
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at)
}

/** People (kind 0) and notes (kind 1) matching text, from the search relays. */
/** Kind 0 only: the read-only sign-in's "find yourself by name". */
export async function searchPeople(text, { limit = 20, relays = SEARCH_RELAYS } = {}) {
  return dedupePeople(await pool.querySync(relays, { kinds: [0], search: text, limit }, { maxWait: 6000 }))
}

export async function searchNostr(text, { limit = 20, relays = SEARCH_RELAYS } = {}) {
  const [people, notes] = await Promise.all([
    pool.querySync(relays, { kinds: [0], search: text, limit }, { maxWait: 6000 }),
    pool.querySync(relays, { kinds: [1], search: text, limit }, { maxWait: 6000 }),
  ])
  return { people: dedupePeople(people), notes: sortNotes(notes) }
}
