// The user's web of trust on the web: their follows, and the people those follows follow, built from the follows'
// contact lists (kind 3). Popular counts votes with the same set (popular.js trustSet); the Web of Trust tab draws it
// (wot-map.js) and lists it (My Web). The iPhone reads a deeper graph its relay builds every day (vouches, followers,
// rebuild); the web has only the lists, so it shows three layers: follows, the extended network (people at least
// EXTENDED_MIN of your follows follow) and further out. Everything here is other people's data and stays in memory.
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"

const HEX64 = /^[0-9a-f]{64}$/

/** How many of your follows must follow someone for them to be in your extended network: the iPhone's cut-off for
 *  the people its relay calls Close (TrustMap.closeVouches). */
export const EXTENDED_MIN = 10
/** How many people of the extended network, and of further out, the map draws: picked by key so the same people
 *  show every time (TrustMap.hazeCap). My Web lists all of them. */
export const FURTHER_CAP = 2_500
export const EXTENDED_CAP = 2_500

// The follows' contact lists this session: each follow's newest list once it has come back. A follow whose list didn't
// come back (a timeout, a relay that was down) is asked again on a later call, after RETRY_MS, so one bad answer doesn't
// empty the web and Popular for the session. Requests in flight are shared: Popular and the Web tab loading at once
// download each list once.
export const RETRY_MS = 60_000
let listCache = { me: "", lists: new Map(), tried: new Map(), inflight: new Map() }

/**
 * The newest contact list of each follow, from the profile relay (purplepag.es keeps them; asking every read relay
 * multiplied a 20-50 KB-per-list download by the number of relays), in chunks of 250 that go out together. Asked for:
 * follows with no list yet, unless one was asked for less than `retryMs` ago (0 asks again now) or is on its way.
 * `query` and `now` are for tests. -> Map(follow pubkey -> kind 3), only the follows whose list has come back
 */
export async function followLists(me, follows, { relays = PROFILE_RELAYS, query = (r, f, o) => pool.querySync(r, f, o), retryMs = RETRY_MS, now = Date.now } = {}) {
  if (listCache.me !== me) listCache = { me, lists: new Map(), tried: new Map(), inflight: new Map() }
  const { lists, tried, inflight } = listCache
  const t = now()
  const waits = new Set()
  const want = []
  for (const pk of uniq(follows)) {
    if (lists.has(pk)) continue
    if (inflight.has(pk)) { waits.add(inflight.get(pk)); continue }
    if (tried.has(pk) && t - tried.get(pk) < retryMs) continue
    want.push(pk)
  }
  for (let i = 0; i < want.length; i += 250) {
    const chunk = want.slice(i, i + 250), wanted = new Set(chunk)
    const job = query(uniq(relays), { kinds: [3], authors: chunk, limit: chunk.length }, { maxWait: 8000 })
      .catch(() => [])
      .then(evs => {
        for (const ev of evs) if (ev?.kind === 3 && wanted.has(ev.pubkey) && !(lists.get(ev.pubkey)?.created_at >= ev.created_at)) lists.set(ev.pubkey, ev)
        for (const pk of chunk) { tried.set(pk, t); inflight.delete(pk) }
      })
    for (const pk of chunk) inflight.set(pk, job)
    waits.add(job)
  }
  await Promise.all(waits)
  const mine = new Map()
  for (const pk of follows) if (lists.has(pk)) mine.set(pk, lists.get(pk))
  return mine
}

/** How many of these follows' lists haven't come back (the Web tab says so, and offers to ask again). */
export const missingLists = follows => uniq(follows).filter(pk => !listCache.lists.has(pk)).length

const followedBy = ev => uniq((ev?.tags ?? []).filter(t => t[0] === "p" && HEX64.test(t[1] ?? "")).map(t => t[1]))

/**
 * The web from the follows' lists. -> {
 *   me, follows: [pk], extended: [pk], further: [pk] (all of them, most-linked first),
 *   linkers: Map(pk -> [the follows who follow them]), followsMe: Set(follows whose list has the user),
 *   layerOf(pk) -> "me" | "follow" | "extended" | "further" | null
 * }
 * Blocked people are hidden everywhere, as in the feeds: a blocked follow is left off too, and nobody is reached
 * through one. (The screen builds the web once and applies blocks with filterWeb, which gives the same result.)
 * `extendedMin` is for tests.
 */
export function buildWeb(me, allFollows, lists, { blocked = new Set(), extendedMin = EXTENDED_MIN } = {}) {
  const follows = allFollows.filter(f => !blocked.has(f))
  const followSet = new Set(follows)
  const linkers = new Map()
  const followsMe = new Set()
  for (const f of follows) {
    for (const pk of followedBy(lists.get(f))) {
      if (pk === me) { followsMe.add(f); continue }
      if (followSet.has(pk) || blocked.has(pk)) continue
      const by = linkers.get(pk)
      if (by) by.push(f); else linkers.set(pk, [f])
    }
  }
  // Follows link each other too: who of your follows also follows this follow.
  for (const f of follows) for (const pk of followedBy(lists.get(f))) if (followSet.has(pk) && pk !== f) {
    const by = linkers.get(pk)
    if (by) by.push(f); else linkers.set(pk, [f])
  }
  const byLinks = (a, b) => (linkers.get(b)?.length ?? 0) - (linkers.get(a)?.length ?? 0) || (a < b ? -1 : 1)
  const extended = [], further = []
  for (const [pk, by] of linkers) {
    if (followSet.has(pk)) continue
    ;(by.length >= extendedMin ? extended : further).push(pk)
  }
  extended.sort(byLinks); further.sort(byLinks)
  return assemble(me, follows, extended, further, linkers, followsMe, extendedMin)
}

function assemble(me, follows, extended, further, linkers, followsMe, extendedMin) {
  const layer = new Map([[me, "me"], ...follows.map(f => [f, "follow"]), ...extended.map(p => [p, "extended"]), ...further.map(p => [p, "further"])])
  return { me, follows: [...follows], extended, further, linkers, followsMe, extendedMin, layerOf: pk => layer.get(pk) ?? null }
}

/**
 * The web with `blocked` people taken out, as buildWeb with those blocks would give it, without reading every list
 * again: only the people a blocked follow links, and the blocked people themselves, change. `lists` is what the web was
 * built from.
 */
export function filterWeb(web, lists, blocked) {
  const hit = [...blocked].filter(pk => web.layerOf(pk))
  if (!hit.length) return web
  const gone = new Set(hit)
  const touched = new Set()
  for (const f of hit) if (web.layerOf(f) === "follow") for (const pk of followedBy(lists.get(f))) touched.add(pk)
  const linkers = new Map(web.linkers)
  for (const pk of gone) linkers.delete(pk)
  for (const pk of touched) {
    if (gone.has(pk) || !linkers.has(pk)) continue
    const by = linkers.get(pk).filter(f => !gone.has(f))
    if (by.length) linkers.set(pk, by); else linkers.delete(pk)
  }
  const follows = web.follows.filter(f => !gone.has(f))
  const keep = pk => !gone.has(pk) && !touched.has(pk)
  const extended = web.extended.filter(keep), further = web.further.filter(keep)
  let moved = false
  for (const pk of touched) {
    if (gone.has(pk) || web.layerOf(pk) === "follow" || web.layerOf(pk) === "me" || !linkers.has(pk)) continue
    ;(linkers.get(pk).length >= web.extendedMin ? extended : further).push(pk)
    moved = true
  }
  if (moved) {
    const byLinks = (a, b) => (linkers.get(b)?.length ?? 0) - (linkers.get(a)?.length ?? 0) || (a < b ? -1 : 1)
    extended.sort(byLinks); further.sort(byLinks)
  }
  const followsMe = new Set([...web.followsMe].filter(f => !gone.has(f)))
  return assemble(web.me, follows, extended, further, linkers, followsMe, web.extendedMin)
}

/** The people of a layer the map draws: up to `cap`, picked by key (TrustMap.haze), so the same people show.
 *  Used for the extended network and further out; My Web lists everyone. */
export function shownByKey(list, cap = FURTHER_CAP) {
  if (list.length <= cap) return list
  return list.map(pk => ({ pk, rank: fraction(pk, 16) })).sort((a, b) => a.rank - b.rank || (a.pk < b.pk ? -1 : 1)).slice(0, cap).map(x => x.pk)
}

/**
 * One line saying how someone is linked to you, as the iPhone's trust card says it (TrustPathText):
 * "You follow them", "Followed by Ann and Bob, who you follow", "Followed by Ann, Bob and 12 others you follow".
 * `name(pk)` gives a display name.
 */
export function trustPathText(web, pk, name) {
  const layer = web.layerOf(pk)
  if (layer === "me") return "This is you"
  const by = web.linkers.get(pk) ?? []
  if (layer === "follow") {
    const back = web.followsMe.has(pk) ? " · they follow you" : ""
    return `You follow them${back}`
  }
  if (!by.length) return "Not in your web"
  const names = by.slice(0, 2).map(name)
  if (by.length === 1) return `Followed by ${names[0]}, who you follow`
  if (by.length === 2) return `Followed by ${names[0]} and ${names[1]}, who you follow`
  const rest = by.length - 2
  return `Followed by ${names[0]}, ${names[1]} and ${rest} other${rest === 1 ? "" : "s"} you follow`
}

/** A number from 0 to 1 from a pubkey's characters at `offset` on: the iPhone's TrustMap.fraction (FNV-1a over the
 *  hex string's bytes), so a person sits in the same place on the web map as on the phone. */
export function fraction(pubkey, offset) {
  let hash = 2_166_136_261
  for (let i = offset; i < pubkey.length; i++) hash = Math.imul(hash ^ pubkey.charCodeAt(i), 16_777_619) >>> 0
  return hash / 4_294_967_296
}
