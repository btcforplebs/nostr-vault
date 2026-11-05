// The diVines feed (the iPhone's ReelsFeedService): short looping videos published as NIP-71 addressable short-video
// events (kind 34236), one per page, newest first. Most live on diVine's own relay, so it is asked alongside the read
// relays. Following asks for your follows' videos; Global for your web of trust's (everyone's while you follow nobody).
// Strangers' videos live in memory only: nothing here is written to Haven.
import { pool, uniq } from "../net/pool.js"
import { globalTrust, trustedFilters } from "./trust.js"

export const REEL_KIND = 34236
export const DIVINE_RELAY = "wss://relay.divine.video"
export const REEL_SCOPES = [{ id: "following", label: "Following" }, { id: "global", label: "Global" }]
export const PAGE = 100
/** Pages in a row that brought no playable video before Older stops asking (ReelsFeedService.reachedEnd). */
export const EMPTY_PAGES_MAX = 4

const KEY = "nv-reels-scope"
export function loadScope(storage = globalThis.localStorage) {
  const s = storage?.getItem(KEY)
  return REEL_SCOPES.some(x => x.id === s) ? s : "following"
}
export const saveScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s)

const key = url => String(url).toLowerCase().replace(/\/+$/, "")
/** diVine's relay first, then the read relays without it (ReelsFeedService.relayURLs). */
export const reelRelays = readRelays => [DIVINE_RELAY, ...uniq(readRelays.map(u => String(u).replace(/\/+$/, ""))).filter(u => key(u) !== key(DIVINE_RELAY))]

const isHttp = u => /^https?:\/\//i.test(u ?? "")
const VIDEO_EXT = /\.(mp4|m4v|mov|webm|m3u8)(\?|#|$)/i

/** Each NIP-92 imeta tag as { url, m, dim, image, … }, the first value of a repeated field kept. */
export function imetaFields(tags) {
  return tags.filter(t => t[0] === "imeta" && t.length >= 2).map(t => {
    const f = {}
    for (const field of t.slice(1)) {
      const i = String(field).indexOf(" ")
      if (i < 0) continue
      const k = field.slice(0, i), v = field.slice(i + 1).trim()
      if (!(k in f) && v) f[k] = v
    }
    return f
  })
}

/** "1080x1920" -> 0.5625 (width / height), or null. */
export function aspectOf(dim) {
  const m = /^(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$/i.exec(String(dim ?? "").trim())
  return m && +m[1] > 0 && +m[2] > 0 ? +m[1] / +m[2] : null
}

/**
 * One page of the feed: the event and the one video it plays (Reel.init), or null. A content warning keeps it out (a
 * warned video autoplaying full screen defeats the warning). The video: the first imeta URL that says video/ or looks
 * like one, else an older NIP-71 bare `url` tag. -> { id, pubkey, createdAt, address, video, mime, poster, aspect,
 * title, caption, event }
 */
export function parseReel(ev) {
  if (ev?.kind !== REEL_KIND || !ev.id || !/^[0-9a-f]{64}$/.test(ev.pubkey ?? "")) return null
  const tags = Array.isArray(ev.tags) ? ev.tags : []
  if (tags.some(t => t[0] === "content-warning")) return null
  const imeta = imetaFields(tags)
  let pick = null
  for (const e of imeta) {
    if (!isHttp(e.url)) continue
    if (/^video\//i.test(e.m ?? "") || (!e.m && VIDEO_EXT.test(e.url))) { pick = { url: e.url, mime: e.m ?? null, entry: e }; break }
  }
  if (!pick) {
    const url = tags.find(t => t[0] === "url" && t.length >= 2)?.[1]
    if (isHttp(url)) pick = { url, mime: tags.find(t => t[0] === "m" && t.length >= 2)?.[1] ?? null, entry: null }
  }
  if (!pick) return null
  const tag = n => tags.find(t => t[0] === n && t.length >= 2)?.[1]
  const poster = pick.entry?.image ?? pick.entry?.thumb ?? tag("image") ?? tag("thumb")
  const title = tag("title")?.trim()
  return {
    id: ev.id, pubkey: ev.pubkey, createdAt: ev.created_at, address: `${REEL_KIND}:${ev.pubkey}:${tag("d") ?? ""}`,
    video: pick.url, mime: pick.mime, poster: isHttp(poster) ? poster : null, aspect: aspectOf(pick.entry?.dim),
    title: title || null, caption: String(ev.content ?? "").replace(pick.url, "").trim(), event: ev,
  }
}

export const newestFirst = (a, b) => b.createdAt - a.createdAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0)

/**
 * Adds a page's events to what is shown (ReelsFeedService.handle + publish). `shown`: the reels on screen, in order;
 * they keep their place. A newer version of an address replaces an older one not yet shown; an older one is dropped.
 * The same video twice is one reel. Blocked people and, with `trust`, anyone outside it are left out. Arrivals are
 * sorted newest first and added after what is shown, so the video under the viewer's thumb never jumps.
 */
export function mergeReels(shown, events, { blocked = new Set(), trust = null } = {}) {
  const byAddress = new Map(shown.map(r => [r.address, r]))
  const ids = new Set(shown.map(r => r.id)), videos = new Set(shown.map(r => r.video))
  const fresh = new Map()
  for (const ev of events) {
    const r = parseReel(ev)
    if (!r || ids.has(r.id) || blocked.has(r.pubkey) || (trust && !trust.has(r.pubkey))) continue
    const old = fresh.get(r.address) ?? byAddress.get(r.address)
    if (old) {
      if (old.createdAt >= r.createdAt || ids.has(old.id)) continue
      videos.delete(old.video)
    }
    if (videos.has(r.video)) continue
    fresh.set(r.address, r); videos.add(r.video)
  }
  return [...shown, ...[...fresh.values()].sort(newestFirst)]
}

/** The filter for a page, or null for Following with no follows. */
export function reelFilter(scope, follows, until = null) {
  const f = { kinds: [REEL_KIND], limit: PAGE, ...(until ? { until } : {}) }
  if (scope !== "following") return f
  return follows.length ? { ...f, authors: follows } : null
}

/** Where the next page starts: the newest of each relay's oldest event, less one, so a dense relay doesn't skip what a
 *  sparse one never sent; null when no relay sent anything (the end). */
export function nextCursor(oldestByRelay) {
  const all = Object.values(oldestByRelay).filter(Number.isFinite)
  return all.length ? Math.max(...all) - 1 : null
}

/**
 * One page: each relay asked on its own, so each one's oldest event is known. -> { events, cursor, answered } where
 * `answered` is false when no relay answered at all (a network failure, not the end). `query(relays, filter)` for tests.
 */
export async function fetchReelPage({ scope, me, follows, readRelays, until = null, trustOf,
  query = (r, f) => pool.querySync(r, f, { maxWait: 10000 }) }) {
  const filter = reelFilter(scope, follows, until)
  if (!filter) return { events: [], cursor: null, answered: true, noFollows: true, trust: null }
  const trust = scope === "global" ? await globalTrust(me, follows, trustOf) : null
  const filters = trust ? trustedFilters(filter, trust) : [filter]
  const relays = reelRelays(readRelays)
  let answered = false
  const oldest = {}
  const pages = await Promise.all(relays.map(async r => {
    try {
      const evs = (await Promise.all(filters.map(f => query([r], f)))).flat()
      answered = true
      for (const e of evs) if (e?.kind === REEL_KIND) oldest[r] = Math.min(oldest[r] ?? Infinity, e.created_at)
      return evs
    } catch { return [] }
  }))
  return { events: pages.flat(), cursor: nextCursor(oldest), answered, noFollows: false, trust }
}

/** The iPhone's empty diVines (ReelsFeedView.emptyTitle / emptyMessage), and which button it offers. */
export function reelsEmpty({ scope, noFollows, failed }) {
  if (noFollows) return { title: "You aren't following anyone yet", detail: "Switch to Global to see everyone's videos.", action: "global" }
  if (failed) return { title: "Could not reach any relay", detail: "diVines come from relays, so this one needs a connection.", action: "retry" }
  return scope === "following"
    ? { title: "No videos from your follows", detail: "Nobody you follow has posted a diVine video recently.", action: "global" }
    : { title: "No videos found", detail: "No diVine videos came back from the relays.", action: "retry" }
}
