// Someone else's profile: their relay list, follow list and notes. Notes come from their NIP-65 write relays (where
// they publish). They are kept in memory here, not in Haven: /feed is the Following feed's store, and opening a
// stranger's profile mustn't fill it. The screen reads Haven /feed (what feed sync saved, for people you follow)
// merged with this memory.
import { pool, relayLists, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { newestList } from "./follows.js"
import { nprofileEncode } from "nostr-tools/nip19"

export const PERSON_PAGE = 50
// Notes fetched per profile, for the profiles opened most recently; the oldest profile is dropped past this.
const KEEP_PROFILES = 10
const fetched = new Map() // pubkey -> Map(id -> event)
function remember(pubkey, evs) {
  const have = fetched.get(pubkey) ?? new Map()
  fetched.delete(pubkey)
  fetched.set(pubkey, have)
  for (const ev of evs) have.set(ev.id, ev)
  while (fetched.size > KEEP_PROFILES) fetched.delete(fetched.keys().next().value)
}
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

/** Their kind 10002 and kind 3 from the user's read relays and the index relays. -> { relays: {read, write}, contacts } */
export async function fetchPersonLists(pubkey, hintRelays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...hintRelays, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { kinds: [3, 10002], authors: [pubkey] }, { maxWait: 6000 })
  const mine = evs.filter(e => e.pubkey === pubkey)
  return { relays: relayLists(newest(mine.filter(e => e.kind === 10002))), contacts: newestList(mine, pubkey) }
}

/** Their notes from Haven /feed and from what this page fetched, newest first, once each. */
export async function readPersonNotes(vault, pubkey, { limit = PERSON_PAGE, until } = {}) {
  const saved = await vault.feed.query({ kinds: [1], authors: [pubkey], limit, ...(until ? { until } : {}) })
  const byId = new Map()
  for (const ev of [...saved, ...(fetched.get(pubkey)?.values() ?? [])])
    if (ev.pubkey === pubkey && ev.kind === 1 && (!until || ev.created_at <= until)) byId.set(ev.id, ev)
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at).slice(0, limit)
}

/** One page of their notes (before `until`, if set) from their write relays, kept in memory. -> notes the network had */
export async function syncPersonNotes(vault, pubkey, writeRelays, { until, limit = PERSON_PAGE, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...writeRelays, ...DEFAULT_RELAYS]), { kinds: [1], authors: [pubkey], limit, ...(until ? { until } : {}) }, { maxWait: 8000 })
  const theirs = evs.filter(e => e.pubkey === pubkey && e.kind === 1)
  remember(pubkey, theirs)
  return theirs.length
}

const articles = new Map() // pubkey -> [kind 30023], for the same profiles as `fetched`
/** Their articles (kind 30023) from their write relays, kept in memory like their notes. -> [event] */
export async function fetchPersonArticles(pubkey, writeRelays, { limit = 50, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (articles.has(pubkey)) return articles.get(pubkey)
  const evs = await query(uniq([...writeRelays, ...DEFAULT_RELAYS]), { kinds: [30023], authors: [pubkey], limit }, { maxWait: 8000 })
  const theirs = evs.filter(e => e.pubkey === pubkey && e.kind === 30023)
  articles.set(pubkey, theirs)
  while (articles.size > KEEP_PROFILES) articles.delete(articles.keys().next().value)
  return theirs
}

/** Their page on Brainstorm, the web's trust explorer (NostrWebLink.swift profile link). */
export const brainstormLink = pubkey => `https://brainstorm.world/p/${nprofileEncode({ pubkey })}`
