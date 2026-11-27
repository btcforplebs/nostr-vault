// A profile's Followers count, as the iPhone's ProfileFeedLoader.fetchFollowerCount: each relay's own NIP-45 COUNT of
// the kind 3s that name the profile, and the largest one kept. Relays hold different subsets of contact lists, so
// adding their answers would count people twice; the largest single answer is the closest to the real number. damus
// and primal answer COUNT, most others refuse it. Vertex (the iPhone's first choice) is off there until turned on
// in Privacy and needs a local key, and the web has neither the setting nor the relay's follower ledger, so it is not
// asked here.
import { pool } from "./pool.js"

// Not the read defaults: of those five only damus and primal answer COUNT.
export const COUNT_RELAYS = ["wss://relay.damus.io", "wss://relay.primal.net"]
const ASK_MS = 6000
/** Answers kept for this long, so opening a profile again shows its number at once. */
export const KEEP_MS = 10 * 60 * 1000

const kept = new Map() // pubkey -> { count, at }

/** One relay's COUNT of `filter` (or of several filters at once, an array), or null when it refuses, fails or takes
 *  longer than `ms`. */
export async function relayCount(url, filter, { ms = ASK_MS, ensure = u => pool.ensureRelay(u) } = {}) {
  let timer
  try {
    const relay = await ensure(url)
    const n = await Promise.race([relay.count(Array.isArray(filter) ? filter : [filter], {}), new Promise(r => { timer = setTimeout(() => r(null), ms) })])
    return Number.isInteger(n) && n >= 0 ? n : null
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/** The kept count for pubkey, or undefined. `web`: the in-web count's key (fetchFollowersInWeb). */
export function keptFollowers(pubkey, now = Date.now(), web = "") {
  const hit = kept.get(web ? `${pubkey}:${web}` : pubkey)
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

/** Authors per filter and filters per COUNT ask: 250 keys in one filter is what both COUNT relays took (11-27); a
 *  thousand in one filter made damus drop the socket, four filters of 250 in one ask didn't. */
export const WEB_CHUNK = 250
export const WEB_FILTERS = 4

/** Who the in-web counts count: the gate's web and your own keys, without anyone blocked (useWebTrust's `gate`). */
export const webKeysOf = gate => [...new Set([...(gate?.web ?? []), ...(gate?.own ?? [])])].filter(k => !gate?.blocked?.has(k))

/** The kept key for an in-web count: the web changes size as the follows' lists come in (useGateWeb fails closed). */
export const webKey = webKeys => `web${webKeys.length}`

/**
 * Followers inside your web (Logen 2026-11-27: on your own profile and on everyone else's): how many of `webKeys`
 * (the gate's web, net/web-gate.js) have a kind 3 naming `pubkey`, as each relay's NIP-45 COUNT with the web as the
 * authors. Only a number comes back, never the lists (a list is 20-50 KB; the iPhone dropped the follower-list ask for
 * that). The web goes out WEB_CHUNK keys a filter and WEB_FILTERS filters an ask; for each ask the largest relay answer
 * is kept (as fetchFollowers) and the asks are added, since their authors don't overlap. `onCount` gets the total so
 * far. -> the total, or null when no relay counted any ask
 */
export async function fetchFollowersInWeb(pubkey, webKeys, onCount = () => {}, { relays = COUNT_RELAYS, count = relayCount, now = Date.now } = {}) {
  const authors = [...new Set(webKeys)].filter(k => k && k !== pubkey)
  const asks = []
  for (let i = 0; i < authors.length; i += WEB_CHUNK * WEB_FILTERS) {
    const part = authors.slice(i, i + WEB_CHUNK * WEB_FILTERS), filters = []
    for (let j = 0; j < part.length; j += WEB_CHUNK) filters.push({ kinds: [3], "#p": [pubkey], authors: part.slice(j, j + WEB_CHUNK) })
    asks.push(filters)
  }
  const key = `${pubkey}:${webKey(webKeys)}`
  if (!asks.length) { kept.set(key, { count: 0, at: now() }); onCount(0); return 0 }
  const best = asks.map(() => null)
  const total = () => best.some(n => n != null) ? best.reduce((a, n) => a + (n ?? 0), 0) : null
  await Promise.all(asks.flatMap((filters, i) => relays.map(async url => {
    const n = await count(url, filters)
    if (n == null || n <= (best[i] ?? -1)) return
    best[i] = n
    const t = total()
    kept.set(key, { count: t, at: now() })
    onCount(t)
  })))
  return total()
}
