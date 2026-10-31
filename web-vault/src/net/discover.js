// Discover: notes from your extended network, as on the iPhone (FeedService+ExtendedNetwork.swift,
// FeedService+FeedSubscription.swift `.discovery`). The network is the people your follows follow, not you and not your
// follows, ranked by how many of your follows follow them (ContactManager.rankExtendedNetwork), top 500. The follows'
// contact lists come from wot.js followLists, the same lists the Web of Trust tab and Popular use. Strangers' notes:
// held in memory, never written to Haven /feed, as Global's.
import { pool, uniq } from "./pool.js"
import { FEED_KINDS } from "./sync.js"
import { followLists } from "./wot.js"

/** ContactManager.rankExtendedNetwork's maxResults. */
export const DISCOVER_MAX = 500
/** Authors per REQ: a 500-author filter can pass a relay's message size cap (the globe's split, PR 712). */
const AUTHORS_PER_REQ = 250

/** The people `lists` (follow pubkey -> kind 3) reach that are not `me`, a follow or blocked, most-followed first
 *  (ties by pubkey), at most `max`. Each follow's list counts once. */
export function extendedNetwork(me, follows, lists, { blocked = new Set(), max = DISCOVER_MAX } = {}) {
  const skip = new Set([me, ...follows])
  const counts = new Map()
  for (const f of follows) {
    if (blocked.has(f)) continue
    const seen = new Set()
    for (const t of lists.get(f)?.tags ?? []) {
      const pk = t[0] === "p" ? t[1] : null
      if (!/^[0-9a-f]{64}$/.test(pk ?? "") || skip.has(pk) || blocked.has(pk) || seen.has(pk)) continue
      seen.add(pk)
      counts.set(pk, (counts.get(pk) ?? 0) + 1)
    }
  }
  return [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1)).slice(0, max).map(([pk]) => pk)
}

/** The network for `me`: the follows' lists (fetched once per session, kept as the WoT tab keeps them), ranked.
 *  `lists` is for tests. */
export async function discoverNetwork(me, follows, { blocked, lists = (m, f) => followLists(m, f) } = {}) {
  if (!follows.length) return []
  return extendedNetwork(me, follows, await lists(me, follows), { blocked })
}

/** One page of Discover, newest first, once each: feed notes by `network`, older than `until` when given. Nothing is
 *  stored. `query` is for tests. */
export async function fetchDiscover(network, relays, { limit = 100, until, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (!network.length) return []
  const authors = new Set(network)
  const page = { kinds: FEED_KINDS, limit, ...(until ? { until } : {}) }
  const asks = []
  for (let i = 0; i < network.length; i += AUTHORS_PER_REQ)
    asks.push(query(uniq(relays), { ...page, authors: network.slice(i, i + AUTHORS_PER_REQ) }, { maxWait: 8000 }))
  const byId = new Map()
  for (const ev of (await Promise.all(asks)).flat())
    if (ev?.id && authors.has(ev.pubkey) && FEED_KINDS.includes(ev.kind) && !byId.has(ev.id)) byId.set(ev.id, ev)
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at).slice(0, limit)
}
