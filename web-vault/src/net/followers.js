// A profile's Followers count, as the iPhone's ProfileFeedLoader.fetchFollowerCount: each relay's own NIP-45 COUNT of
// the kind 3s that name the profile, and the largest one kept. Relays hold different subsets of contact lists, so
// adding their answers would count people twice; the largest single answer is the closest to the real number. damus
// and primal answer COUNT, most others refuse it. Vertex (the iPhone's first choice) is off there until turned on
// in Privacy and needs a local key, and the web has neither the setting nor the relay's follower ledger, so it is not
// asked here.
import { pool, DEFAULT_RELAYS } from "./pool.js"

export const COUNT_RELAYS = DEFAULT_RELAYS
const ASK_MS = 6000
/** Answers kept for this long, so opening a profile again shows its number at once. */
export const KEEP_MS = 10 * 60 * 1000

const kept = new Map() // pubkey -> { count, at }

/** One relay's COUNT, or null when it refuses, fails or takes longer than `ms`. */
export async function relayCount(url, filter, { ms = ASK_MS, ensure = u => pool.ensureRelay(u) } = {}) {
  let timer
  try {
    const relay = await ensure(url)
    const n = await Promise.race([relay.count([filter], {}), new Promise(r => { timer = setTimeout(() => r(null), ms) })])
    return Number.isInteger(n) && n >= 0 ? n : null
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/** The kept count for pubkey, or undefined. */
export function keptFollowers(pubkey, now = Date.now()) {
  const hit = kept.get(pubkey)
  return hit && now - hit.at < KEEP_MS ? hit.count : undefined
}

/**
 * Asks every relay at once; `onCount` gets each new largest answer as it lands. Resolves to the largest, or null when
 * no relay counted.
 */
export async function fetchFollowers(pubkey, onCount = () => {}, { relays = COUNT_RELAYS, count = relayCount, now = Date.now } = {}) {
  const filter = { kinds: [3], "#p": [pubkey] }
  let best = null
  await Promise.all(relays.map(async url => {
    const n = await count(url, filter)
    if (n == null || n <= (best ?? -1)) return
    best = n
    kept.set(pubkey, { count: n, at: now() })
    onCount(n)
  }))
  return best
}
