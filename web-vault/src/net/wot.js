// The user's web of trust on the web: their follows, and the people those follows follow, built from the follows'
// contact lists (kind 3). Popular counts votes with the same set (popular.js trustSet); the Web of Trust tab draws it
// (wot-map.js) and lists it (My Web). The iPhone reads a deeper graph its relay builds every day (vouches, followers,
// rebuild); the web has only the lists, so it shows three layers: follows, the extended network (people at least
// EXTENDED_MIN of your follows follow) and further out. Everything here is other people's data and stays in memory,
// except your own follows' lists, which this browser keeps so a reload doesn't download them again (wot-store.js).
import { pool, PROFILE_RELAYS, uniq } from "./pool.js"
import { emptyKept, wotStore } from "./wot-store.js"

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
// Two caches: "home" for the user's own follows (the Web tab and Popular), "visit" for the person whose web "See their
// web" put in the middle, so walking round other people's webs never empties the user's own. Each is for one person
// at a time. The user's own ("home") are also kept in this browser (wot-store.js) and read back on the next load, so a
// reload doesn't download every follow's list again; a follow's list is only asked for again `since` the last check,
// at most every REFRESH_MS, or in full when they are a new follow. Follows whose list didn't come back are kept too and
// asked for again after REFRESH_MS, not on every load: purplepag.es sends only ~560 of 1,054 follows' lists, and asking
// for the rest on each load was 8-18 MB of mostly older copies of lists.
export const RETRY_MS = 60_000
export const REFRESH_MS = 6 * 3600_000
// How long a group of 250 lists may take. A group is ~12 MB: in a first sign-in's busy page 8 s cut some off part way
// (the relay itself sends them in ~3.5 s and ends with EOSE, which closes the ask sooner).
export const LISTS_WAIT_MS = 20_000
const newCache = me => ({ me, lists: new Map(), tried: new Map(), inflight: new Map(), disk: null, checkedAt: 0, refreshed: false, missed: new Map() })
const caches = { home: newCache(""), visit: newCache("") }

/**
 * The newest contact list of each follow, from the profile relay (purplepag.es keeps them; asking every read relay
 * multiplied a 20-50 KB-per-list download by the number of relays), in chunks of 250 that go out together. Asked for:
 * follows with no list yet, unless one was asked for less than `retryMs` ago (0 asks again now) or is on its way.
 * `slot` is "home" (the user's follows) or "visit" (someone else's, for See their web). `query` and `now` are for tests.
 * -> Map(follow pubkey -> kind 3), only the follows whose list has come back
 */
export async function followLists(me, follows, { relays = PROFILE_RELAYS, query = (r, f, o) => pool.querySync(r, f, o), retryMs = RETRY_MS, now = Date.now, slot = "home", store = slot === "home" ? wotStore(me) : null, refreshMs = REFRESH_MS, reachable = relayUp, loadMs = LOAD_TIMEOUT_MS } = {}) {
  if (caches[slot].me !== me) caches[slot] = newCache(me)
  const cache = caches[slot]
  const { lists, tried, inflight } = cache
  const t = now()
  // What this browser kept, once per page load: lists a relay has sent since then are newer and win. Read BOOT_GRACE_MS
  // after the page starts, once it is idle: the screens build their sets from it straight away (Messages' trust and the
  // unread badge, ~0.36 s for 1,054 follows), and done during boot that put a reload's first note ~0.4 s later. Still
  // seconds sooner than the download it replaces.
  // A read that never answers (an IndexedDB open that hangs) counts as nothing kept after loadMs.
  if (store && !cache.disk) cache.disk = idle().then(() => within(store.load(), loadMs, emptyKept())).then(({ lists: kept, misses, checkedAt }) => {
    for (const [pk, ev] of kept) if (!(lists.get(pk)?.created_at >= ev.created_at)) lists.set(pk, ev)
    cache.missed = misses
    cache.checkedAt = checkedAt
  })
  if (cache.disk) await cache.disk
  const keep = (evs, always = false, misses = []) => { if (store && (evs.length || misses.length || always)) return store.save(evs, cache.checkedAt ||= Math.floor(t / 1000), misses, Math.floor(t / 1000)) }
  if (store && cache.checkedAt && !cache.refreshed && t - cache.checkedAt * 1000 > refreshMs) {
    cache.refreshed = true
    refreshLists(cache, follows, { relays, query, keep, reachable, now, at: Math.floor(t / 1000) })
  }
  const waits = new Set()
  const want = []
  for (const pk of uniq(follows)) {
    if (lists.has(pk)) continue
    if (inflight.has(pk)) { waits.add(inflight.get(pk)); continue }
    if (tried.has(pk) && t - tried.get(pk) < retryMs) continue
    // Missing on an earlier load: not again until REFRESH_MS has passed (Try again, retryMs 0, asks now).
    if (retryMs && cache.missed.has(pk) && t - cache.missed.get(pk) * 1000 < refreshMs) continue
    want.push(pk)
  }
  for (let i = 0; i < want.length; i += 250) {
    const chunk = want.slice(i, i + 250), wanted = new Set(chunk)
    const started = now()
    const job = query(uniq(relays), { kinds: [3], authors: chunk, limit: chunk.length }, { maxWait: LISTS_WAIT_MS })
      .catch(() => [])
      .then(evs => {
        const got = []
        for (const ev of evs) if (ev?.kind === 3 && wanted.has(ev.pubkey) && !(lists.get(ev.pubkey)?.created_at >= ev.created_at)) { lists.set(ev.pubkey, ev); got.push(ev) }
        for (const pk of chunk) { tried.set(pk, t); inflight.delete(pk) }
        // An answer with some of the group's lists but not someone's: kept as missing. A failed or empty answer, or one
        // cut off at LISTS_WAIT_MS (querySync ends a timeout as if the relay had sent EOSE), keeps nothing, so it is
        // asked again after RETRY_MS as before.
        // An answer as long as the limit may be a relay's cap rather than all it has: no misses from that either.
        const cut = now() - started >= LISTS_WAIT_MS - 100 || evs.length >= chunk.length
        const misses = !cut && evs.some(ev => wanted.has(ev?.pubkey)) ? chunk.filter(pk => !lists.has(pk)) : []
        for (const pk of misses) cache.missed.set(pk, Math.floor(t / 1000))
        return keep(got, false, misses)
      })
    for (const pk of chunk) inflight.set(pk, job)
    waits.add(job)
  }
  await Promise.all(waits)
  const mine = new Map()
  for (const pk of follows) if (lists.has(pk)) mine.set(pk, lists.get(pk))
  return mine
}

export const BOOT_GRACE_MS = 1500
export const LOAD_TIMEOUT_MS = 5000
const relayUp = urls => Promise.any(urls.map(url => pool.ensureRelay(url, { connectionTimeout: 5000 })))
function within(p, ms, fallback) {
  let timer
  return Promise.race([p, new Promise(r => { timer = setTimeout(() => r(fallback), ms) })]).finally(() => clearTimeout(timer))
}
const idle = () => new Promise(r => {
  if (!globalThis.requestIdleCallback) return r() // node (the tests)
  setTimeout(() => requestIdleCallback(() => r(), { timeout: 3000 }), Math.max(0, BOOT_GRACE_MS - performance.now()))
})

// The lists already held that changed since the last check: a relay sends only those, so this is a few small answers
// rather than every list again. Runs behind the caller; the next followLists call has what it found.
async function refreshLists(cache, follows, { relays, query, keep, reachable, now, at }) {
  const held = uniq(follows).filter(pk => cache.lists.has(pk))
  const since = cache.checkedAt - 600
  // An empty answer is the usual one (nobody changed their list), and it is also what an unreachable relay gives: only
  // a check that reached a relay, and wasn't cut off, moves the check time on. Otherwise the next load asks again.
  if (globalThis.navigator?.onLine === false) return
  try { await reachable(uniq(relays)) } catch { return }
  const started = now()
  let ok = true
  const got = []
  await Promise.all(Array.from({ length: Math.ceil(held.length / 250) }, (_, k) => held.slice(k * 250, k * 250 + 250)).map(chunk => {
    const wanted = new Set(chunk)
    return query(uniq(relays), { kinds: [3], authors: chunk, since, limit: chunk.length }, { maxWait: 8000 })
      .then(evs => { for (const ev of evs) if (ev?.kind === 3 && wanted.has(ev.pubkey) && !(cache.lists.get(ev.pubkey)?.created_at >= ev.created_at)) { cache.lists.set(ev.pubkey, ev); got.push(ev) } })
      .catch(() => { ok = false })
  }))
  // A check that failed keeps the old time, so the next load asks from there again.
  if (now() - started >= 8000 - 100) ok = false
  if (ok) cache.checkedAt = at
  await keep(got, ok)
}

/** How many of these follows' lists haven't come back (the Web tab says so, and offers to ask again). */
export const missingLists = (follows, slot = "home") => uniq(follows).filter(pk => !caches[slot].lists.has(pk)).length

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

/** Bridges a card names and shows; more than this reads "+ more" (TrustPath.shownBridges). */
export const SHOWN_BRIDGES = 5

/**
 * How someone reaches you, as the iPhone's TrustPath: { reach, bridges, hasMore, all }. `reach` is "you", "follow"
 * (1 hop), "bridged" (someone you follow follows them: 2 hops) or "outside". `all` is every follow of yours who
 * follows them, sorted by key as the phone sorts them; `bridges` is its first SHOWN_BRIDGES. The phone's "web" (in its
 * relay's graph with no bridge found) can't happen here: this web is made of bridges. null with no web yet.
 */
export function trustPath(web, pk) {
  if (!web) return null
  if (pk === web.me) return { reach: "you", bridges: [], hasMore: false, all: [] }
  const all = [...(web.linkers.get(pk) ?? [])].sort()
  const bridges = all.slice(0, SHOWN_BRIDGES)
  const reach = web.layerOf(pk) === "follow" ? "follow" : bridges.length ? "bridged" : "outside"
  return { reach, bridges, hasMore: all.length > SHOWN_BRIDGES, all }
}

/**
 * The trust card's one line, word for word the iPhone's (TrustPathText.label): "You follow them · 1 hop",
 * "You follow them · also followed by Ann and Bob", "Followed by Ann, Bob + more you follow · 2 hops",
 * "Not in your web · no one you follow follows them". `name(pk)` gives a display name.
 */
export function trustPathText(web, pk, name) {
  const path = trustPath(web, pk)
  if (!path) return "Tracing how they reach you…"
  switch (path.reach) {
    case "you": return "This is you."
    case "follow": return path.bridges.length ? `You follow them · also followed by ${bridgeNames(path, name)}` : "You follow them · 1 hop"
    case "bridged": return `Followed by ${bridgeNames(path, name)} you follow · 2 hops`
    default: return "Not in your web · no one you follow follows them"
  }
}

function bridgeNames(path, name) {
  const names = path.bridges.slice(0, 2).map(name)
  return path.bridges.length > names.length || path.hasMore ? `${names.join(", ")} + more` : names.join(" and ")
}

/** The WoT tab's layer picker, the iPhone's names (TrustMap.Layer): [id, title, the web's layer it shows]. */
export const LAYERS = [["everyone", "Everyone", null], ["following", "Following", "follow"], ["close", "Vouched", "extended"], ["furtherOut", "Further out", "further"]]

/** People in each layer, never counting you (TrustMap.layerCounts): { everyone, following, close, furtherOut }. */
export function layerCounts(web) {
  const following = web.follows.length, close = web.extended.length, furtherOut = web.further.length
  return { everyone: following + close + furtherOut, following, close, furtherOut }
}

/**
 * A number from 0 to 1 from a pubkey's characters at `offset` on, as the iPhone's TrustMap.fraction does it, so a
 * person sits in the same place on the web as on the phone: the 8 characters there read as a hex number
 * (`UInt32(hex, radix: 16)`, which also takes a leading "+", and a "-" when the value is 0), or, when they aren't hex
 * (only for malformed keys), FNV-1a over the UTF-8 bytes from byte `offset` on. Test fixtures come from the Swift
 * function itself, compiled from TrustMap.swift.
 */
export function fraction(pubkey, offset) {
  const v = hexPrefix(Array.from(pubkey).slice(offset, offset + 8).join(""))
  if (v !== null) return v / 4_294_967_296
  let hash = 2_166_136_261
  const bytes = utf8.encode(pubkey)
  for (let i = offset; i < bytes.length; i++) hash = Math.imul(hash ^ bytes[i], 16_777_619) >>> 0
  return hash / 4_294_967_296
}
const utf8 = new TextEncoder()

/** Swift's UInt32(s, radix: 16) for an 8-character string: the value, or null where Swift gives nil. */
export function hexPrefix(s) {
  if (Array.from(s).length !== 8) return null
  const m = /^([+-]?)([0-9a-fA-F]+)$/.exec(s)
  if (!m) return null
  const v = parseInt(m[2], 16)
  return m[1] === "-" && v !== 0 ? null : v
}
