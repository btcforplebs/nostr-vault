// The counting rules for nostrvault.app/stats: which notes are Nostr Vault's, which platform posted them, and the
// public totals. Pure functions, no network: run.mjs fetches, this file decides. Tested by test/count.test.mjs.

/** Notes counted: kind 1 notes and NIP-22 comments, the two kinds the apps tag (EventPublisher.appendClientTag). */
export const COUNTED_KINDS = [1, 1111]

/** The first day any app shipped the client tag. Notes before it are not looked for. */
export const SINCE = "2026-05-01"

/**
 * Keys never counted: the project's own accounts, its test keys and an agent account (prefix match, first 8 hex).
 * The same list as RESEARCH/NV_USER_STATS_2026_11_14.md's scans.
 */
export const EXCLUDED_PREFIXES = [
  "61bf790b", // Logen
  "4f5f4c74", // the Nostr Vault account
  "75462f4d", // the Mac Haven key
  "43f63a7b", // test key
  "e538c93b", // test key
  "3c93935d", // agent account
  "dc073905", // MyNostrSpace (project account)
]

export const isExcluded = pubkey => EXCLUDED_PREFIXES.some(p => String(pubkey).startsWith(p))

/** The platforms the page shows, in its order. */
export const PLATFORMS = ["Android", "iPhone", "iPad", "Mac", "Linux", "Web"]

/**
 * The platform a ["client", value] names, from the values the apps write: "Nostr Vault on iOS" (iPhone),
 * "… on iPadOS", "… on MacOS", "… on Android", "… on Linux" (the Linux desktop window), "… on Web". null when the value is not Nostr Vault's;
 * "Other" for a Nostr Vault value that names no platform this list knows.
 */
export function platformOf(clientValue) {
  if (typeof clientValue !== "string" || !clientValue.startsWith("Nostr Vault")) return null
  const on = clientValue.slice("Nostr Vault".length).trim().replace(/^on\s+/i, "").toLowerCase()
  if (on === "ios") return "iPhone"
  if (on === "ipados") return "iPad"
  if (on === "macos") return "Mac"
  if (on === "android") return "Android"
  if (on === "linux") return "Linux"
  if (on === "web") return "Web"
  return "Other"
}

/** The platform of a Nostr Vault note, or null when the note is not one we count. */
export function nvPlatform(event) {
  if (!event || !COUNTED_KINDS.includes(event.kind) || !Array.isArray(event.tags)) return null
  const tag = event.tags.find(t => Array.isArray(t) && t[0] === "client")
  return tag ? platformOf(tag[1]) : null
}

/**
 * Folds notes into one record per poster: { first, last, notes: { platform: count } } (unix seconds).
 * Excluded keys and notes that are not Nostr Vault's are skipped; a note seen twice (two relays) counts once.
 */
export function collectPosters(events) {
  const seen = new Set()
  const posters = new Map()
  for (const ev of events) {
    if (!ev || seen.has(ev.id)) continue
    const platform = nvPlatform(ev)
    if (!platform || isExcluded(ev.pubkey)) continue
    seen.add(ev.id)
    const rec = posters.get(ev.pubkey) ?? { first: ev.created_at, last: ev.created_at, notes: {} }
    rec.first = Math.min(rec.first, ev.created_at)
    rec.last = Math.max(rec.last, ev.created_at)
    rec.notes[platform] = (rec.notes[platform] ?? 0) + 1
    posters.set(ev.pubkey, rec)
  }
  return posters
}

/**
 * Today's scan over what earlier scans found. A poster found again takes today's record (it was read in full);
 * one not found again keeps the old record, so a relay dropping old notes never shrinks the all-time total.
 */
export function mergePosters(previous, today) {
  const merged = new Map(previous)
  for (const [pubkey, rec] of today) {
    const old = previous.get(pubkey)
    merged.set(pubkey, old ? { ...rec, first: Math.min(old.first, rec.first), last: Math.max(old.last, rec.last) } : rec)
  }
  for (const pubkey of merged.keys()) if (isExcluded(pubkey)) merged.delete(pubkey)
  return merged
}

/** A poster's main platform: the one with the most notes (ties go to the earlier one in PLATFORMS). */
export function mainPlatform(rec) {
  let best = null
  for (const p of [...PLATFORMS, "Other"]) {
    const n = rec.notes?.[p] ?? 0
    if (n > 0 && (best === null || n > rec.notes[best])) best = p
  }
  return best ?? "Other"
}

const DAY = 86400

/**
 * The public file: totals only. No keys, no list, no per-person figure.
 * `now` is unix seconds; `downloads` is the GitHub total or null when it could not be read.
 */
export function publicTotals(posters, { now, downloads, relays }) {
  const byPlatform = Object.fromEntries(PLATFORMS.map(p => [p, 0]))
  let active7 = 0
  let active30 = 0
  for (const rec of posters.values()) {
    const main = mainPlatform(rec)
    if (main in byPlatform) byPlatform[main]++
    if (rec.last > now - 7 * DAY) active7++
    if (rec.last > now - 30 * DAY) active30++
  }
  return {
    generated_at: new Date(now * 1000).toISOString(),
    posting_users: posters.size,
    by_platform: byPlatform,
    active_7d: active7,
    active_30d: active30,
    github_downloads: downloads,
    since: SINCE,
    relays,
    method: "Counted from public posts tagged Nostr Vault. Totals only: no tracking, no list of people.",
  }
}

/** The poster records as plain JSON (the local state file), and back. */
export const postersToJson = posters => Object.fromEntries(posters)
export const postersFromJson = obj => new Map(Object.entries(obj ?? {}).filter(([k, v]) => /^[0-9a-f]{64}$/.test(k) && v && typeof v.last === "number"))
