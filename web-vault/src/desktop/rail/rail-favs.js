// The left rail's favourites (Logen, 2026-11-03): the sections, and what the user pinned beside them (a feed, a
// person, a hashtag, a list or a relay's feed), in the user's order. No styles, so tests can import it. Sidebar.jsx
// draws them; RailEdit.jsx edits them. They are kept in the same saved layout as Your space (space/space-layout.js
// `rail`), so they sync with it through the user's own vault (net/space-sync.js).
//
// A favourite is one of:
//   { type: "section", id }          a rail section: feed, search, messages, wot, vault, profile
//   { type: "feed", mode }           a feed from the Feed's picker (Global, Articles, …), by its id
//   { type: "person", pubkey }       someone's profile
//   { type: "hashtag", tag }         a hashtag's feed (lowercase, no #)
//   { type: "list", pubkey, d, name } a people list (kind 30000, its author and `d`) as a feed of their notes
//   { type: "relay", url }           one relay's feed (wss:// or ws://)
// A type or section this app does not know (from a newer app) is kept where it is and not drawn.
import { normalizeTag } from "../../net/feeds.js"

/** The rail's sections, in their default order. Feed is the home section and can't be taken off. */
export const SECTION_IDS = ["feed", "search", "messages", "wot", "vault", "profile"]
export const HOME = "feed"
export const TYPES = ["section", "feed", "person", "hashtag", "list", "relay"]
/** Most favourites the rail keeps. */
export const MAX_FAVS = 40

const HEX = /^[0-9a-f]{64}$/

/** A relay address as kept: trimmed, wss:// or ws://, no trailing slash; "" when it isn't one. */
export function normalizeRelay(url) {
  const s = String(url ?? "").trim()
  if (!/^wss?:\/\/[^\s/]+/i.test(s)) return ""
  try {
    const u = new URL(s)
    if (u.protocol !== "wss:" && u.protocol !== "ws:") return ""
    return `${u.protocol}//${u.host}${u.pathname.replace(/\/+$/, "")}${u.search}`
  } catch { return "" }
}

/** A clean copy of a saved favourite, or null when it is broken. Unknown types keep their own fields. */
export function cleanFav(f) {
  if (!f || typeof f !== "object" || typeof f.type !== "string" || !f.type) return null
  switch (f.type) {
    case "section": return typeof f.id === "string" && f.id ? { type: "section", id: f.id } : null
    case "feed": return typeof f.mode === "string" && f.mode ? { type: "feed", mode: f.mode } : null
    case "person": return HEX.test(f.pubkey ?? "") ? { type: "person", pubkey: f.pubkey } : null
    case "hashtag": { const tag = normalizeTag(f.tag); return tag ? { type: "hashtag", tag } : null }
    case "list": {
      if (!HEX.test(f.pubkey ?? "") || typeof f.d !== "string" || !f.d || f.d.length > 200) return null
      const name = typeof f.name === "string" ? f.name.trim().slice(0, 80) : ""
      return { type: "list", pubkey: f.pubkey, d: f.d, ...(name ? { name } : {}) }
    }
    case "relay": { const url = normalizeRelay(f.url); return url ? { type: "relay", url } : null }
    default: return TYPES.includes(f.type) ? null : { ...f }
  }
}

/** One key per favourite, so the same thing is never pinned twice. */
export function favKey(f) {
  switch (f.type) {
    case "section": return `section:${f.id}`
    case "feed": return `feed:${f.mode}`
    case "person": return `person:${f.pubkey}`
    case "hashtag": return `hashtag:${f.tag}`
    case "list": return `list:${f.pubkey}:${f.d}`
    case "relay": return `relay:${f.url}`
    default: return `${f.type}:${JSON.stringify(f)}`
  }
}

/** Where a favourite goes. The Feed reads ?feed=, ?tag=, ?list= and ?relay= (net/feeds.js linkChoice). */
export function favHref(f) {
  switch (f.type) {
    case "section": return `#/${f.id}`
    case "feed": return `#/feed?feed=${encodeURIComponent(f.mode)}`
    case "person": return `#/profile/${f.pubkey}`
    case "hashtag": return `#/feed?tag=${encodeURIComponent(f.tag)}`
    case "list": return `#/feed?list=${f.pubkey}:${encodeURIComponent(f.d)}`
    case "relay": return `#/feed?relay=${encodeURIComponent(f.url)}`
    default: return null
  }
}

/** A relay's short name for the rail: its host without a leading "relay.", e.g. "damus.io", "nos.lol". */
export const relayName = url => { try { return new URL(url).host.replace(/^relay\./, "") } catch { return url } }

/** Whether this app can draw a favourite. */
export const known = (f, feedIds = []) =>
  f.type === "section" ? SECTION_IDS.includes(f.id) : f.type === "feed" ? feedIds.includes(f.mode) : favHref(f) != null

/** The rail before any edit: the sections, in order. */
export const defaultRail = () => SECTION_IDS.map(id => ({ type: "section", id }))

/**
 * Any saved value -> a clean rail. Broken entries and repeats drop out, unknown ones stay, Feed is always there (on
 * top when it was missing). No saved rail at all is the default one.
 */
export function normalizeRail(saved) {
  if (!Array.isArray(saved)) return defaultRail()
  const seen = new Set(), out = []
  for (const raw of saved) {
    const f = cleanFav(raw)
    if (!f) continue
    const k = favKey(f)
    if (seen.has(k)) continue
    seen.add(k)
    out.push(f)
    if (out.length >= MAX_FAVS) break
  }
  if (!seen.has(`section:${HOME}`)) out.unshift({ type: "section", id: HOME })
  return out
}

/** The favourites to draw, in order. */
export const shownFavs = (rail, feedIds) => rail.filter(f => known(f, feedIds))
/** The sections taken off the rail, to add back. */
export const missingSections = rail => SECTION_IDS.filter(id => !rail.some(f => f.type === "section" && f.id === id))

/** Pin a favourite at the end; already there or the rail is full: unchanged. */
export function pin(rail, fav) {
  const f = cleanFav(fav)
  if (!f || rail.some(x => favKey(x) === favKey(f)) || rail.length >= MAX_FAVS) return rail
  return [...rail, f]
}
/** Take one off; Feed stays. */
export const unpin = (rail, key) => (key === `section:${HOME}` ? rail : rail.filter(f => favKey(f) !== key))
export const isPinned = (rail, fav) => { const f = cleanFav(fav); return !!f && rail.some(x => favKey(x) === favKey(f)) }

/** Move one up (-1) or down (+1) among the drawn ones; ones not drawn keep their places. */
export function moveFav(rail, key, delta, feedIds) {
  const drawn = shownFavs(rail, feedIds).map(favKey)
  const i = drawn.indexOf(key), j = i + delta
  if (i < 0 || j < 0 || j >= drawn.length) return rail
  const a = rail.findIndex(f => favKey(f) === key), b = rail.findIndex(f => favKey(f) === drawn[j])
  const out = [...rail]
  ;[out[a], out[b]] = [out[b], out[a]]
  return out
}

/** Drop a dragged one just before `beforeKey` (null: at the end). */
export function moveFavBefore(rail, key, beforeKey) {
  if (key === beforeKey) return rail
  const moving = rail.find(f => favKey(f) === key)
  if (!moving) return rail
  const rest = rail.filter(f => f !== moving)
  const i = beforeKey == null ? rest.length : rest.findIndex(f => favKey(f) === beforeKey)
  if (i < 0) return rail
  const out = [...rest.slice(0, i), moving, ...rest.slice(i)]
  return out.every((f, k) => f === rail[k]) ? rail : out
}

/** Whether two rails are the same, in the same order. */
export const sameRail = (a, b) => a.length === b.length && a.every((f, i) => favKey(f) === favKey(b[i]))
