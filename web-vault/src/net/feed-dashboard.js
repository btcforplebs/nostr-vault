// The Feed Dashboard (parity #19): what the people you follow did in the last 24 hours, ported from the iPhone's
// FeedDashboardStore / FeedDashboardSnapshot (HavenApp/Services/FeedDashboardStore.swift). One load asks each kind's
// usual relays once, all filtered to your follows and the last day, and every card is derived from that one answer by
// buildDashboard, which is pure so the tests pin it. Nothing is saved: the dashboard only reads.
import { pool, uniq } from "./pool.js"
import { bolt11Sats } from "./notifications.js"
import { LIVE_KIND, STREAM_RELAY, isPlayableLive, parseStream } from "../readers/live.js"
import { MARKET_KINDS, MARKET_RELAYS, parseListing } from "../readers/market.js"
import { RECIPE_TOPICS } from "../readers/longform.js"

export const WINDOW_S = 24 * 60 * 60
/** Relays reject very large author lists. */
export const AUTHORS_PER_FILTER = 500
export const POLL_KIND = 1068, ARTICLE_KIND = 30023, DIVINE_KIND = 34236
const RELAY_CAP = 6
const HEX64 = /^[0-9a-f]{64}$/

/** The tiles' feeds, in the iPhone's order, with its names. Reels (diVines) has no web feed, so its tile opens nothing. */
export const TILE_NAMES = { polls: "Polls", marketplace: "Marketplace", articles: "Articles", reels: "Reels", recipes: "Recipes", music: "Music" }

/** FeedDashboardView.compact: 999, 1.2k, 12k, 1.2M. */
export function compact(n) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 10_000) return `${Math.floor(n / 1000)}k`
  if (n >= 1_000) return `${(n / 1000).toFixed(1)}k`
  return String(n)
}

/** NIP-10: the last `e` tag is the one replied or reacted to. */
const lastTag = (name, tags) => tags.findLast(t => t.length >= 2 && t[0] === name && String(t[1]).length === 64)?.[1]
const firstTag = (name, tags) => tags.find(t => t.length >= 2 && t[0] === name && t[1])?.[1]
/** The first line that isn't empty, trimmed, at most 80 characters; null when it's only spaces. */
export function oneLine(text) {
  const line = String(text ?? "").split(/[\r\n]+/).find(Boolean)?.trim() ?? ""
  return line ? [...line].slice(0, 80).join("") : null
}
const TRACK = /^https?:\/\/(www\.)?wavlake\.com\/track\/[0-9a-z-]+/i
export const hasWavlakeTrack = content => String(content).includes("wavlake.com") && String(content).split(/\s+/).some(w => TRACK.test(w))

/**
 * FeedDashboardSnapshot.build. `events`: everything the load brought (notes, reactions, polls, articles, diVines,
 * listings, live streams); `zapReceipts`: kind 9735s p-tagged to `owner`; `newFollowers`: how many followed since.
 * -> { posts, activePeople, satsReceived, newFollowers, live, mostActive, popular, trending, tiles }
 */
export function buildDashboard({ events = [], zapReceipts = [], follows, owner, blocked = new Set(), since, now, newFollowers = 0 }) {
  const followSet = follows instanceof Set ? follows : new Set(follows)
  const s = { posts: 0, activePeople: 0, satsReceived: 0, newFollowers, live: [], mostActive: [], popular: [], trending: [], tiles: [] }
  const seen = new Set(), postsBy = new Map(), tagPeople = new Map(), likedBy = new Map(), notesById = new Map()
  const polls = [], articles = [], recipes = [], diVines = [], listings = [], music = [], liveByAddress = new Map()
  const add = (map, key, pk) => { let set = map.get(key); if (!set) map.set(key, set = new Set()); set.add(pk) }

  for (const ev of events) {
    if (!ev?.id || seen.has(ev.id)) continue
    seen.add(ev.id)
    const { pubkey, kind, created_at: at } = ev
    if (!HEX64.test(pubkey ?? "") || blocked.has(pubkey) || !Number.isInteger(kind) || !Number.isFinite(at)) continue
    const tags = Array.isArray(ev.tags) ? ev.tags : []
    const content = typeof ev.content === "string" ? ev.content : ""

    if (kind === LIVE_KIND) {
      // Hosted on a service, a stream's author is the service and the host is in a `p` tag: either followed counts.
      const stream = parseStream(ev)
      if (!stream || !(followSet.has(stream.host) || followSet.has(pubkey)) || blocked.has(stream.host) || !isPlayableLive(stream, now)) continue
      const old = liveByAddress.get(stream.address)
      if (!old || old.createdAt < stream.createdAt) liveByAddress.set(stream.address, stream)
      continue
    }
    if (!followSet.has(pubkey) || at < since) continue

    if (kind === 1 || kind === 6) {
      s.posts++
      postsBy.set(pubkey, (postsBy.get(pubkey) ?? 0) + 1)
      if (kind === 1) {
        notesById.set(ev.id, ev)
        for (const t of tags) {
          if (t.length < 2) continue
          if (t[0] === "t") { const tag = String(t[1]).toLowerCase().trim(); if (tag && [...tag].length <= 40) add(tagPeople, tag, pubkey) }
          if (t[0] === "q") add(likedBy, t[1], pubkey)
        }
        if (hasWavlakeTrack(content)) music.push(ev)
      } else {
        const target = lastTag("e", tags)
        if (target) add(likedBy, target, pubkey)
      }
    } else if (kind === 7) {
      const target = lastTag("e", tags)
      if (content !== "-" && target) add(likedBy, target, pubkey)
    } else if (kind === POLL_KIND) polls.push(ev)
    else if (kind === ARTICLE_KIND) {
      const topics = tags.filter(t => t.length >= 2 && t[0] === "t").map(t => String(t[1]).toLowerCase())
      ;(topics.some(t => RECIPE_TOPICS.includes(t)) ? recipes : articles).push(ev)
    } else if (kind === DIVINE_KIND) diVines.push(ev)
    else if (MARKET_KINDS.includes(kind)) { const l = parseListing(ev); if (l) listings.push(l) }
  }

  const byCountThenId = (a, b) => b.count - a.count || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
  s.activePeople = postsBy.size
  s.mostActive = [...postsBy].map(([id, count]) => ({ id, count })).sort(byCountThenId)
  // Two people make a trend; one person's tag is just their tag.
  s.trending = [...tagPeople].filter(([, p]) => p.size >= 2).map(([id, p]) => ({ id, count: p.size })).sort(byCountThenId).slice(0, 10)
  s.popular = [...likedBy].filter(([, p]) => p.size >= 2).map(([id, p]) => ({ id, count: p.size, note: notesById.get(id) ?? null }))
    .sort(byCountThenId).slice(0, 3).map(({ id, count, note }) => ({ id, people: count, note }))
  s.live = [...liveByAddress.values()].sort((a, b) => (b.viewers ?? 0) - (a.viewers ?? 0) || b.createdAt - a.createdAt)

  // A listing edited twice in a day is still one listing.
  const listed = new Set()
  const uniqueListings = listings.sort((a, b) => b.createdAt - a.createdAt).filter(l => {
    const key = `${l.kind}:${l.pubkey}:${l.d ?? l.id}`
    return !listed.has(key) && listed.add(key)
  })
  const title = ev => firstTag("title", ev.tags ?? []) ?? firstTag("alt", ev.tags ?? []) ?? oneLine(ev.content)
  const tile = (feed, list, preview) => {
    if (!list.length) return null
    const newest = list.reduce((a, b) => (b.created_at > a.created_at ? b : a))
    return { feed, count: list.length, preview: preview(newest) }
  }
  s.tiles = [
    tile("polls", polls, ev => oneLine(ev.content)),
    uniqueListings.length ? { feed: "marketplace", count: uniqueListings.length, preview: uniqueListings[0].title || null } : null,
    tile("articles", articles, title),
    tile("reels", diVines, title),
    tile("recipes", recipes, title),
    tile("music", music, () => null),
  ].filter(Boolean)

  // Sats: each receipt once; an unreadable invoice counts nothing.
  const counted = new Set()
  for (const r of zapReceipts) {
    if (r?.kind !== 9735 || counted.has(r.id) || !(r.created_at >= since) || !Array.isArray(r.tags)) continue
    if (!r.tags.some(t => t[0] === "p" && t[1] === owner)) continue
    counted.add(r.id)
    s.satsReceived += bolt11Sats(firstTag("bolt11", r.tags))
  }
  return s
}

/** Popular notes the load didn't bring (older than a day, or by someone you don't follow) attached, the rest dropped. */
export function attachPopular(snapshot, found) {
  const byId = new Map(found.filter(e => e?.id).map(e => [e.id, e]))
  return { ...snapshot, popular: snapshot.popular.map(p => (p.note ? p : { ...p, note: byId.get(p.id) ?? null })).filter(p => p.note) }
}

/** Everyone the cards draw a face or a name for. */
export const profilesOf = s => uniq([...s.mostActive.slice(0, 12).map(p => p.id), ...s.live.map(l => l.host), ...s.popular.map(p => p.note?.pubkey).filter(Boolean)])

const chunks = list => Array.from({ length: Math.ceil(list.length / AUTHORS_PER_FILTER) }, (_, i) => list.slice(i * AUTHORS_PER_FILTER, (i + 1) * AUTHORS_PER_FILTER))
const cap = relays => uniq(relays.map(u => String(u).trim().replace(/\/+$/, "")).filter(Boolean)).slice(0, RELAY_CAP)

/** The filters one load asks, per relay group (FeedDashboardStore.refresh). Exported for the tests. */
export function dashboardFilters({ follows, owner, since }) {
  const parts = chunks(follows)
  const by = (kinds, limit) => parts.map(authors => ({ kinds, authors, since, limit }))
  return {
    notes: follows.length ? [...by([1, 6], 1500), ...by([7], 1500), ...by([POLL_KIND, ARTICLE_KIND, DIVINE_KIND], 200)] : [],
    listings: follows.length ? by(MARKET_KINDS, 100) : [],
    live: follows.length ? [...by([LIVE_KIND], 100), ...parts.map(p => ({ kinds: [LIVE_KIND], "#p": p, since, limit: 100 }))] : [],
    zaps: owner ? [{ kinds: [9735], "#p": [owner], since, limit: 500 }] : [],
  }
}

/**
 * One load: the day's events from your follows on your read relays, listings on the market relays, streams on the live
 * relays and zaps to you on your own, then the snapshot. A relay that doesn't answer gives nothing; it never fails the
 * load. `query(relays, filter)` is for tests.
 */
export async function fetchDashboard({ follows, owner, readRelays, blocked, newFollowers = 0, now = Math.floor(Date.now() / 1000),
  query = (r, f) => pool.querySync(r, f, { maxWait: 8000 }) }) {
  const since = now - WINDOW_S
  const f = dashboardFilters({ follows, owner, since })
  const ask = (relays, filters) => Promise.all(filters.map(x => query(relays, x).catch(() => []))).then(r => r.flat())
  const read = cap(readRelays)
  const [notes, listings, live, zaps] = await Promise.all([
    ask(read, f.notes), ask(cap(MARKET_RELAYS), f.listings), ask(cap([STREAM_RELAY, ...readRelays]), f.live), ask(read, f.zaps)])
  const snapshot = buildDashboard({ events: [...notes, ...listings, ...live], zapReceipts: zaps, follows, owner, blocked, since, now, newFollowers })
  const missing = snapshot.popular.filter(p => !p.note).map(p => p.id)
  if (!missing.length) return snapshot
  return attachPopular(snapshot, await query(read, { ids: missing, limit: missing.length }).catch(() => []))
}

/** New followers in the window, from the follower lists this browser keeps (vault-lists.js followersOf). */
export const newFollowersSince = (followers, since) => followers.filter(f => f.at >= since).length
