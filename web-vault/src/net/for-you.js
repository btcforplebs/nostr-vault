// Search's "For you", as the iPhone's (Models/SearchRecommendations.swift): people your follows follow, your topics,
// and notes that match them. All judged here from your follows' contact lists (wot.js followLists, shared with Popular,
// the Web tab and Notifications), your hashtag list (kind 10015) and the notes Haven holds. No recommendation server.
const HEX64 = /^[0-9a-f]{64}$/

/** Below this many of your follows, a follow-of-a-follow is noise (SearchRecommendations.minVouches). */
export const MIN_VOUCHES = 2

/** A hashtag as InterestList.normalize keeps it: no leading #, lower case. */
export const normalizeTag = t => (typeof t === "string" ? t.trim().replace(/^#+/, "").toLowerCase() : "")

/** pubkey -> how many of `follows` follow them, from the follows' kind 3s (`lists`: Map(follow -> kind 3)). */
export function vouchesFrom(follows, lists) {
  const out = new Map()
  for (const f of new Set(follows)) {
    const seen = new Set()
    for (const t of lists.get(f)?.tags ?? []) if (t[0] === "p" && HEX64.test(t[1] ?? "") && !seen.has(t[1])) {
      seen.add(t[1])
      out.set(t[1], (out.get(t[1]) ?? 0) + 1)
    }
  }
  return out
}

/** People your follows follow most: not you, not followed, not blocked, at least MIN_VOUCHES. Most vouched first, ties
 *  by pubkey so the rail doesn't reshuffle. -> [{ pubkey, vouches }] */
export function recommendedPeople(vouches, { following, me, blocked = new Set(), limit = 8 }) {
  return [...vouches]
    .filter(([pk, n]) => n >= MIN_VOUCHES && pk !== me && !following.has(pk) && !blocked.has(pk))
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, limit)
    .map(([pubkey, n]) => ({ pubkey, vouches: n }))
}

/** The `t` tags used most across these notes' tag arrays, once per note, merged by case; `excluding` dropped. Ties
 *  alphabetical (HashtagSuggestions.top). */
export function topTags(tagArrays, excluding = new Set(), limit = 8) {
  const counts = new Map()
  for (const tags of tagArrays) {
    const inNote = new Set()
    for (const t of tags ?? []) if (t[0] === "t" && t.length >= 2) { const n = normalizeTag(t[1]); if (n) inNote.add(n) }
    for (const n of inNote) counts.set(n, (counts.get(n) ?? 0) + 1)
  }
  return [...counts].filter(([n]) => !excluding.has(n)).sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, limit).map(([n]) => n)
}

/** Your topics: the hashtags you follow, then the ones on notes you wrote or reacted to, most used first. */
export function interests(followed, engaged, limit = 12) {
  const out = [], seen = new Set()
  for (const t of followed) { const n = normalizeTag(t); if (n && !seen.has(n)) { seen.add(n); out.push(n) } }
  return [...out, ...topTags(engaged, seen, Math.max(0, limit - out.length))].slice(0, limit)
}

/** The hashtags in a kind 10015 (NIP-51 interests), in order. */
export const followedTags = ev => (ev?.tags ?? []).filter(t => t[0] === "t" && t[1]).map(t => t[1])

/**
 * Notes tagged with one of your topics, not yours, not blocked, not ones you reacted to. Ranked by how many topics a
 * note hits, then how close its author is (followed, else vouches), then newest. One per author. -> [event]
 */
export function pickedNotes(notes, { topics, following, vouches, me, blocked = new Set(), seen = new Set(), limit = 5 }) {
  const wanted = new Set(topics.map(normalizeTag).filter(Boolean))
  if (!wanted.size) return []
  const scored = []
  for (const ev of notes) {
    if (ev.pubkey === me || blocked.has(ev.pubkey) || seen.has(ev.id)) continue
    const hit = new Set()
    for (const t of ev.tags ?? []) if (t[0] === "t" && t.length >= 2) { const n = normalizeTag(t[1]); if (wanted.has(n)) hit.add(n) }
    if (!hit.size) continue
    scored.push({ ev, hits: hit.size, close: following.has(ev.pubkey) ? Infinity : (vouches.get(ev.pubkey) ?? 0) })
  }
  scored.sort((a, b) => b.hits - a.hits || (b.close === a.close ? 0 : b.close > a.close ? 1 : -1) || b.ev.created_at - a.ev.created_at || (a.ev.id < b.ev.id ? -1 : 1))
  const authors = new Set(), out = []
  for (const { ev } of scored) {
    if (authors.has(ev.pubkey)) continue
    authors.add(ev.pubkey)
    out.push(ev)
    if (out.length === limit) break
  }
  return out
}

/** Ids of the notes your kind 7s react to (the last e tag, NIP-25). */
export function reactedIds(reactions) {
  const out = new Set()
  for (const r of reactions) {
    const es = (r.tags ?? []).filter(t => t[0] === "e" && HEX64.test(t[1] ?? ""))
    if (es.length) out.add(es[es.length - 1][1])
  }
  return out
}
