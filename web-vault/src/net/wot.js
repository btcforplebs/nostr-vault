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
/** How many further-out people the map draws, picked by key so the same people show every time (TrustMap.hazeCap).
 *  My Web lists all of them. */
export const FURTHER_CAP = 2_500

// The follows' contact lists this session: each follow's newest list, asked for once. A follow added later is asked for
// on its own; nothing already here is downloaded again.
let listCache = { me: "", lists: new Map(), asked: new Set() }

/**
 * The newest contact list of each follow, from the profile relay (purplepag.es keeps them; asking every read relay
 * multiplied a 20-50 KB-per-list download by the number of relays). Only follows not asked for yet this session are
 * asked for, in chunks of 250 that go out together. `query` is for tests. -> Map(follow pubkey -> kind 3)
 */
export async function followLists(me, follows, { relays = PROFILE_RELAYS, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (listCache.me !== me) listCache = { me, lists: new Map(), asked: new Set() }
  const { lists, asked } = listCache
  const want = uniq(follows).filter(pk => !asked.has(pk))
  const chunks = []
  for (let i = 0; i < want.length; i += 250) chunks.push(want.slice(i, i + 250))
  const answers = await Promise.all(chunks.map(chunk => query(uniq(relays), { kinds: [3], authors: chunk, limit: chunk.length }, { maxWait: 8000 })))
  const wanted = new Set(want)
  for (const ev of answers.flat()) if (ev?.kind === 3 && wanted.has(ev.pubkey) && !(lists.get(ev.pubkey)?.created_at >= ev.created_at)) lists.set(ev.pubkey, ev)
  for (const pk of want) asked.add(pk)
  const mine = new Map()
  for (const pk of follows) if (lists.has(pk)) mine.set(pk, lists.get(pk))
  return mine
}

const followedBy = ev => uniq((ev?.tags ?? []).filter(t => t[0] === "p" && HEX64.test(t[1] ?? "")).map(t => t[1]))

/**
 * The web from the follows' lists. -> {
 *   me, follows: [pk], extended: [pk], further: [pk] (all of them, most-linked first),
 *   linkers: Map(pk -> [the follows who follow them]), followsMe: Set(follows whose list has the user),
 *   layerOf(pk) -> "me" | "follow" | "extended" | "further" | null
 * }
 * Blocked people are left out of the extended and further layers, and nobody is reached through a blocked follow
 * (it stays a follow: you made it). `extendedMin` is for tests.
 */
export function buildWeb(me, follows, lists, { blocked = new Set(), extendedMin = EXTENDED_MIN } = {}) {
  const followSet = new Set(follows)
  const linkers = new Map()
  const followsMe = new Set()
  for (const f of follows) {
    if (blocked.has(f)) continue // someone you blocked doesn't vouch for anyone
    for (const pk of followedBy(lists.get(f))) {
      if (pk === me) { followsMe.add(f); continue }
      if (followSet.has(pk) || blocked.has(pk)) continue
      const by = linkers.get(pk)
      if (by) by.push(f); else linkers.set(pk, [f])
    }
  }
  // Follows link each other too: who of your follows also follows this follow.
  for (const f of follows) for (const pk of followedBy(lists.get(f))) if (!blocked.has(f) && followSet.has(pk) && pk !== f) {
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
  const layer = new Map([[me, "me"], ...follows.map(f => [f, "follow"]), ...extended.map(p => [p, "extended"]), ...further.map(p => [p, "further"])])
  return { me, follows: [...follows], extended, further, linkers, followsMe, layerOf: pk => layer.get(pk) ?? null }
}

/** The further-out people the map draws: up to `cap`, picked by key (TrustMap.haze), so the same people show. */
export function furtherShown(further, cap = FURTHER_CAP) {
  if (further.length <= cap) return further
  return further.map(pk => ({ pk, rank: fraction(pk, 16) })).sort((a, b) => a.rank - b.rank || (a.pk < b.pk ? -1 : 1)).slice(0, cap).map(x => x.pk)
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
