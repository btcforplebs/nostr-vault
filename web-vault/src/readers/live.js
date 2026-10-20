// The Live feed (NIP-53 kind 30311), ported from the iPhone's LiveFeedService, LiveStream and LiveChat. Nothing is
// written to Haven: a stream only matters while it runs, and a saved one is a gravestone (of 632 stream events
// pulled on 2026-09-05, 478 had already ended).
import { naddrEncode } from "nostr-tools/nip19"
import { pool, uniq } from "../net/pool.js"
import { zapRequest, zapSats } from "../net/notifications.js"
import { globalTrust } from "./trust.js"

export const LIVE_KIND = 30311
export const CHAT_KIND = 1311
/** Where most streams are published (LiveChat.streamRelay); asked even when it isn't in the read list. */
export const STREAM_RELAY = "wss://relay.zap.stream"
/** Where chat actually is (LiveChat.defaultChatRelays): zap.stream's relay held none of it when measured. */
export const CHAT_RELAYS = ["wss://relay.damus.io", "wss://relay.primal.net", "wss://relay.snort.social"]
/** A `live` stream not republished for an hour is one whose host quit without saying so (NIP-53). */
export const STALE_AFTER = 60 * 60
export const LIVE_SCOPES = [{ id: "following", label: "Following" }, { id: "global", label: "Global" }]
const ADULT = new Set(["nsfw", "porn", "xxx", "nude", "nudes", "onlyfans"])
const KEY = "nv-live-scope"
const HEX64 = /^[0-9a-f]{64}$/

export function loadScope(storage = globalThis.localStorage) {
  const s = storage?.getItem(KEY)
  return LIVE_SCOPES.some(x => x.id === s) ? s : null
}
export const saveScope = (s, storage = globalThis.localStorage) => storage?.setItem(KEY, s)
/** Until the user picks, someone who follows nobody opens on Global: Following could only ever be empty for them. */
export const startScope = (saved, follows) => saved ?? (follows.length ? "following" : "global")

const value = (tags, name) => { const v = tags.find(t => t.length >= 2 && t[0] === name)?.[1]; return typeof v === "string" && v.trim() ? v.trim() : null }
const http = s => { try { const u = new URL(String(s).trim()); return /^https?:$/.test(u.protocol) ? u.href : null } catch { return null } }

/** A relay URL as wss:// or ws:// with a host and no trailing slash, else null. */
export function normalizedRelay(raw) {
  const s = String(raw ?? "").trim().replace(/\/+$/, "")
  try { const u = new URL(s); return /^wss?:$/.test(u.protocol) && u.hostname ? s : null } catch { return null }
}

/** Who the stream is by: a service may publish it with the real host as a `p` tag marked Host. */
export function hostOf(author, tags) {
  return tags.find(t => t.length >= 4 && t[0] === "p" && String(t[3]).toLowerCase() === "host" && t[1])?.[1] ?? author
}

/** Following: the author or the Host is followed. A followed guest doesn't make the stream theirs. */
export const isFollowedStream = (author, tags, follows) => follows.has(author) || follows.has(hostOf(author, tags))

/** Only an HLS playlist plays as a live stream; `streaming` also carries web pages and moq:// links, in any order. */
export function playableUrl(tags) {
  for (const t of tags) {
    if (t.length < 2 || t[0] !== "streaming") continue
    const u = http(t[1])
    if (u && new URL(u).pathname.toLowerCase().endsWith(".m3u8")) return u
  }
  return null
}

/** Still on air at `now`: status live (or none), `ends` not passed, republished within the hour. */
export function isOnAir({ status, createdAt, ends }, now) {
  if (status && status !== "live") return false
  if (ends != null && ends <= now) return false
  return now - createdAt <= STALE_AFTER
}

/** Content-warning labels, an adult t tag, 🔞 or an adult word in the title or summary. */
export function isAdultStream(tags) {
  if (tags.some(t => t[0] === "content-warning" || (t.length >= 2 && t[0] === "t" && ADULT.has(String(t[1]).toLowerCase())))) return true
  if (tags.some(t => t.length >= 2 && t[0] === "L" && String(t[1]).toLowerCase() === "content-warning")) return true
  const text = tags.filter(t => t.length >= 2 && (t[0] === "title" || t[0] === "summary")).map(t => String(t[1]).toLowerCase()).join(" ")
  return text.includes("🔞") || text.split(/[^\p{L}\p{N}]+/u).some(w => ADULT.has(w))
}

/** A 30311 reduced to what the grid and player need, or null without a `d` tag. */
export function parseStream(ev) {
  const tags = Array.isArray(ev?.tags) ? ev.tags : []
  const identifier = value(tags, "d")
  if (ev?.kind !== LIVE_KIND || !identifier || !HEX64.test(ev.pubkey ?? "")) return null
  const previews = uniq(["thumb", "image"].map(n => http(value(tags, n) ?? "")).filter(Boolean))
  const relaysTag = tags.find(t => t.length >= 2 && t[0] === "relays")
  const ends = Number(value(tags, "ends")), viewers = Number(value(tags, "current_participants"))
  return {
    id: ev.id, author: ev.pubkey, host: hostOf(ev.pubkey, tags), identifier, createdAt: ev.created_at,
    address: `${LIVE_KIND}:${ev.pubkey}:${identifier}`,
    title: value(tags, "title"), summary: value(tags, "summary"), image: http(value(tags, "image") ?? ""), previews,
    streaming: playableUrl(tags), status: value(tags, "status"),
    ends: Number.isFinite(ends) && value(tags, "ends") ? ends : null,
    viewers: Number.isInteger(viewers) && viewers >= 0 && value(tags, "current_participants") ? viewers : null,
    chatRelays: relaysTag ? relaysTag.slice(1).map(normalizedRelay).filter(Boolean) : [],
    adult: isAdultStream(tags),
  }
}

/** Shown only while on air AND something can play it. */
export const isPlayableLive = (s, now) => !!s.streaming && isOnAir(s, now)

/** The filters: Following asks by author and by `p` (a service publishing for the host), Global asks for all. */
export function liveFilters(scope, follows) {
  if (scope !== "following") return [{ kinds: [LIVE_KIND], limit: 300 }]
  if (!follows.length) return []
  return [{ kinds: [LIVE_KIND], authors: follows, limit: 300 }, { kinds: [LIVE_KIND], "#p": follows, limit: 300 }]
}

/** From what the relays sent: the newest event per address (an ended stream replaces its live announcement), kept
 *  when by someone followed (Following) or trusted (Global, author or Host in `trust`), not blocked (author or host),
 *  and playable live now. Global with no web yet (`trust` null) shows everyone but adult streams (LiveChat.globalGate). */
export function pickStreams(evs, { scope, follows, trust = null, blocked = new Set(), now = Math.floor(Date.now() / 1000) }) {
  const follow = new Set(follows)
  const by = new Map()
  for (const ev of evs) {
    const s = parseStream(ev)
    if (!s || blocked.has(s.author) || blocked.has(s.host)) continue
    if (scope === "following" && !isFollowedStream(s.author, ev.tags, follow)) continue
    if (scope !== "following" && (trust ? !isFollowedStream(s.author, ev.tags, trust) : s.adult)) continue
    const have = by.get(s.address)
    if (!have || s.createdAt > have.createdAt) by.set(s.address, s)
  }
  return [...by.values()].filter(s => isPlayableLive(s, now)).sort((a, b) => b.createdAt - a.createdAt || (a.address < b.address ? 1 : -1))
}

/** The read relays plus zap.stream's. */
export const liveRelays = read => uniq([...read, STREAM_RELAY].map(u => u.replace(/\/+$/, "")))

/** One load. `query` and `trustOf` are for tests. -> streams, or null when there was nothing to ask. Streams are
 *  rare, so Global's one open filter covers the trusted too (no author-restricted second ask, as on the iPhone). */
export async function fetchStreams({ scope, me, follows, readRelays, blocked, query = (r, f, o) => pool.querySync(r, f, o), trustOf, now }) {
  const filters = liveFilters(scope, follows)
  if (!filters.length) return null
  const trust = scope === "following" ? null : await globalTrust(me, follows, trustOf)
  const evs = (await Promise.all(filters.map(f => query(liveRelays(readRelays), f, { maxWait: 10000 })))).flat()
  return pickStreams(evs, { scope, follows, trust, blocked, now })
}

/** "Open in zap.stream": the stream's naddr, by who signed it, with up to two of its own relays as hints. */
export function streamLink(s) {
  const relays = s.chatRelays.filter(r => /^wss?:\/\//.test(r)).slice(0, 2)
  return `https://zap.stream/${naddrEncode({ kind: LIVE_KIND, pubkey: s.author, identifier: s.identifier, relays })}`
}

/** Where the chat is: the stream's own relays, then the usual chat relays. */
export const chatRelays = s => uniq([...s.chatRelays, ...CHAT_RELAYS])
export const chatFilter = (s, since) => ({ kinds: [CHAT_KIND, 9735], "#a": [s.address], limit: 200, ...(since ? { since } : {}) })

/** A chat row from a 1311 or a 9735 (the payer and comment come from its checked zap request), or null. */
export function chatRow(ev) {
  if (!ev?.id) return null
  if (ev.kind === CHAT_KIND) {
    const text = String(ev.content ?? "").trim()
    return text ? { id: ev.id, who: ev.pubkey, at: ev.created_at, text, sats: 0 } : null
  }
  if (ev.kind !== 9735) return null
  const req = zapRequest(ev)
  if (!req) return null
  return { id: ev.id, who: req.pubkey, at: ev.created_at, text: String(req.content ?? "").trim(), sats: zapSats(ev) }
}

/** Rows oldest first, once each, blocked people left out, the newest `max` kept. */
export function chatRows(evs, blocked = new Set(), max = 200) {
  const by = new Map()
  for (const ev of evs) { const r = chatRow(ev); if (r && !blocked.has(r.who) && !by.has(r.id)) by.set(r.id, r) }
  return [...by.values()].sort((a, b) => a.at - b.at || (a.id < b.id ? -1 : 1)).slice(-max)
}

/** Can this browser play HLS by itself (Safari, iOS)? Elsewhere the stream opens on zap.stream. */
export const playsHls = (video = globalThis.document?.createElement("video")) => !!video?.canPlayType?.("application/vnd.apple.mpegurl")
