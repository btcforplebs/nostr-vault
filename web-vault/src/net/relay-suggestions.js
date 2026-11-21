// Settings › Relays › Recommended (iPhone RelayMatrixView's Recommended page, RelayMatrix.followSuggestions and
// RelayMatrix.fastest): relays the user's follows write to, ranked by how many follows use each, and the well-known
// public relays that answer fastest from this browser (net/relay-probe.js timing). Nothing here signs or publishes.
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"
import { isPublicRelay } from "./never-connect.js"

/** RelayMatrix.wellKnownRelays, in the phone's order. */
export const WELL_KNOWN_RELAYS = [
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://relay.snort.social",
  "wss://relay.btcforplebs.com",
  "wss://relay.nostr.bg",
  "wss://nostr.oxtr.dev",
  "wss://relay.nostr.net",
  "wss://nostr.bitcoiner.social",
]

/** HavenConfig.normalizedRelayURL: trimmed, trailing slashes gone. */
export const normalized = url => String(url ?? "").trim().replace(/\/+$/, "")
/** RelayMatrix.key: one relay however it is spelled. */
export const relayKey = url => normalized(url).toLowerCase()

/** The write relays (write or unmarked) in a kind 10002 (NIP-65). */
export const writeRelaysOf = ev => (ev?.tags ?? []).filter(t => t[0] === "r" && typeof t[1] === "string" && t[2] !== "read").map(t => t[1])

/**
 * RelayMatrix.followSuggestions: relays the follows write to (`outbox`: pubkey -> write relays), most follows first
 * (ties by address), leaving out `taken` (already yours), `blocked` (Never Connect) and relays no other client can reach (not wss,
 * loopback, LAN, .onion). One follow counts once per relay; a relay needs `minimumFollows` follows.
 * -> [{ url, follows }]
 */
export function followSuggestions({ follows, outbox, taken = [], blocked = () => false, minimumFollows = 2, limit = 8 }) {
  const skip = new Set(taken.filter(Boolean).map(relayKey))
  const counts = new Map(), spelling = new Map()
  for (const pubkey of new Set(follows)) {
    const seen = new Set()
    for (const raw of outbox.get(pubkey) ?? []) {
      const url = normalized(raw), k = relayKey(url)
      if (!isPublicRelay(url) || skip.has(k) || seen.has(k) || blocked(url)) continue
      seen.add(k)
      counts.set(k, (counts.get(k) ?? 0) + 1)
      if (!spelling.has(k)) spelling.set(k, url)
    }
  }
  return [...counts]
    .filter(([, n]) => n >= minimumFollows)
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
    .slice(0, limit)
    .map(([k, follows]) => ({ url: spelling.get(k), follows }))
}

/** RelayMatrix.followsWithRelayLists: how many follows have a known write-relay list. */
export const followsWithRelayLists = (follows, outbox) => [...new Set(follows)].filter(pk => (outbox.get(pk) ?? []).length).length

/**
 * RelayMatrix.fastest: the candidates that answered (`ms`: relayKey -> milliseconds), quickest first (ties by
 * address), leaving out `taken` and `blocked` (Never Connect). -> [url]
 */
export function fastest(candidates, ms, { taken = [], blocked = () => false, limit = 5 } = {}) {
  const skip = new Set(taken.filter(Boolean).map(relayKey)), seen = new Set()
  return candidates.map(normalized)
    .filter(url => { const k = relayKey(url); if (skip.has(k) || ms[k] == null || seen.has(k) || blocked(url)) return false; seen.add(k); return true })
    .sort((a, b) => ms[relayKey(a)] - ms[relayKey(b)] || (a < b ? -1 : a > b ? 1 : 0))
    .slice(0, limit)
}

/** The newest kind 10002 per author -> Map pubkey -> write relays. */
export function outboxFrom(events, pubkeys) {
  const want = new Set(pubkeys), newest = new Map()
  for (const e of events) {
    if (e?.kind !== 10002 || !want.has(e.pubkey)) continue
    const had = newest.get(e.pubkey)
    if (!had || e.created_at > had.created_at) newest.set(e.pubkey, e)
  }
  return new Map([...newest].map(([pk, e]) => [pk, writeRelaysOf(e)]))
}

const CHUNK = 200

/**
 * The follows' write relays: Haven's copies first, then the user's read relays and the index relays for the rest
 * (200 authors an ask, as profiles.js). -> Map pubkey -> write relays
 */
export async function followOutboxes({ vault, follows, relays, query = (r, f, o) => pool.querySync(r, f, o) }) {
  const want = uniq(follows), events = []
  for (let i = 0; i < want.length; i += CHUNK) {
    const chunk = want.slice(i, i + CHUNK)
    if (vault?.feed) events.push(...await Promise.resolve(vault.feed.query({ kinds: [10002], authors: chunk })).catch(() => []))
  }
  const have = new Set(events.map(e => e.pubkey))
  const missing = want.filter(pk => !have.has(pk)), asks = []
  const ask = uniq([...relays, ...PROFILE_RELAYS])
  for (let i = 0; i < missing.length; i += CHUNK) {
    asks.push(query(ask, { kinds: [10002], authors: missing.slice(i, i + CHUNK) }, { maxWait: 6000 }).catch(() => []))
  }
  for (const evs of await Promise.all(asks)) events.push(...evs)
  return outboxFrom(events, want)
}
