// Someone else's profile: their relay list, follow list and notes. Notes come from their NIP-65 write relays (where
// they publish). They are kept in memory here, not in Haven: /feed is the Following feed's store, and opening a
// stranger's profile mustn't fill it. The screen reads Haven /feed (what feed sync saved, for people you follow)
// merged with this memory. Also both profiles' Tagged tab (notes by others that tag them) and your own profile's
// older pages, which go into Haven's outbox as syncOwn's do.
import { pool, relayLists, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { newestList } from "./follows.js"
import { nprofileEncode } from "nostr-tools/nip19"

export const PERSON_PAGE = 50
/** The kinds the note tabs are filled from: notes and reposts (ProfileFeedLoader asks for 1, 6, 30023 and polls;
 *  articles come from their own fetch). */
export const NOTE_KINDS = [1, 6]
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

/** Their kind 10002 and kind 3 from the user's read relays and the index relays. When no 10002 comes back (a busy
 *  relay, a socket slot not free in time), asked once more before falling back to the defaults: their notes live on
 *  their write relays, and a stranger's often aren't on the defaults at all (2 of 10, Tara's probe 2026-10-31).
 *  -> { relays: {read, write}, contacts, found } (found: a 10002 came back) */
export async function fetchPersonLists(pubkey, hintRelays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const relays = uniq([...hintRelays, ...DEFAULT_RELAYS, ...PROFILE_RELAYS])
  const filter = { kinds: [3, 10002], authors: [pubkey] }
  let mine = (await query(relays, filter, { maxWait: 6000 })).filter(e => e.pubkey === pubkey)
  if (!mine.some(e => e.kind === 10002)) mine = [...mine, ...(await query(relays, filter, { maxWait: 8000 }).catch(() => [])).filter(e => e.pubkey === pubkey)]
  const list = newest(mine.filter(e => e.kind === 10002))
  return { relays: relayLists(list), contacts: newestList(mine, pubkey), found: !!list }
}

/** Their notes and reposts from Haven /feed and from what this page fetched, newest first, once each. */
export async function readPersonNotes(vault, pubkey, { limit = PERSON_PAGE, until } = {}) {
  const saved = await vault.feed.query({ kinds: NOTE_KINDS, authors: [pubkey], limit, ...(until ? { until } : {}) })
  const byId = new Map()
  for (const ev of [...saved, ...(fetched.get(pubkey)?.values() ?? [])])
    if (ev.pubkey === pubkey && NOTE_KINDS.includes(ev.kind) && (!until || ev.created_at <= until)) byId.set(ev.id, ev)
  return [...byId.values()].sort((a, b) => b.created_at - a.created_at).slice(0, limit)
}

/** One page of their notes and reposts (at or before `until`, if set) from their write relays and, unless `defaults`
 *  is false, the default relays, kept in memory. -> how many the network had */
export async function syncPersonNotes(vault, pubkey, writeRelays, { until, limit = PERSON_PAGE, defaults = true, maxWait = 8000, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...writeRelays, ...(defaults ? DEFAULT_RELAYS : [])]), { kinds: NOTE_KINDS, authors: [pubkey], limit, ...(until ? { until } : {}) }, { maxWait })
  const theirs = evs.filter(e => e.pubkey === pubkey && NOTE_KINDS.includes(e.kind))
  remember(pubkey, theirs)
  return theirs.length
}

/** A profile's opening notes: Haven's first, then the default relays at once (shown as they come), then their own
 *  write relays once their relay list has answered. The load counts as done only when all of those have replied, and
 *  if it still found nothing it asks everything once more with a longer wait (one 8 s try lost a stranger's notes to
 *  a busy relay). Their list may name no write relays (no 10002): then the defaults (primal, snort and the rest) are
 *  their whole set. nos.lol is not added: the pool refuses it (DEAD_RELAY_HOSTS).
 *  -> their notes, newest first */
export async function openPersonNotes(vault, pubkey, listsP, { show = () => {}, limit = PERSON_PAGE, sync = syncPersonNotes, read = readPersonNotes } = {}) {
  const early = sync(vault, pubkey, []).catch(() => 0).then(async () => show(await read(vault, pubkey, { limit })))
  const l = await listsP
  const theirs = l.relays.write.filter(u => !DEFAULT_RELAYS.includes(u))
  await Promise.all([early, theirs.length && sync(vault, pubkey, theirs, { defaults: false }).catch(() => 0)])
  let got = await read(vault, pubkey, { limit })
  if (!got.length) {
    await sync(vault, pubkey, l.relays.write, { maxWait: 12000 }).catch(() => 0)
    got = await read(vault, pubkey, { limit })
  }
  return got
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

const tagged = new Map() // pubkey -> Map(id -> event): notes by others that tag them, for the same profiles as `fetched`
/** One page of notes by others that tag them (ProfileFeedLoader's tagged filter, kind 1 here) at or before `until`,
 *  from `relays` (their read relays: NIP-65 sends mentions there) and the index relays, kept in memory.
 *  -> what is kept for them at or before `until`, newest first */
export async function fetchTagged(pubkey, relays, { until, limit = PERSON_PAGE, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...relays, ...DEFAULT_RELAYS]), { kinds: [1], "#p": [pubkey], limit, ...(until ? { until } : {}) }, { maxWait: 8000 })
  const page = evs.filter(e => e.kind === 1 && e.pubkey !== pubkey && e.tags.some(t => t[0] === "p" && t[1] === pubkey))
  const have = tagged.get(pubkey) ?? new Map()
  tagged.delete(pubkey)
  tagged.set(pubkey, have)
  for (const ev of page) have.set(ev.id, ev)
  while (tagged.size > KEEP_PROFILES) tagged.delete(tagged.keys().next().value)
  return [...have.values()].filter(e => !until || e.created_at <= until).sort((a, b) => b.created_at - a.created_at)
}

/** Your own profile, one page further back than it shows (at or before `until`): the network's page goes into Haven's
 *  outbox, as syncOwn's opening 300 do, then the outbox is read. Offline, the outbox alone. Your notes and reposts are
 *  already signed; nothing here signs. -> the page, newest first */
export async function ownOlder(vault, pubkey, relays, until, { online = true, limit = PERSON_PAGE, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  if (online) await syncOwnPage(vault, pubkey, relays, { until, limit, query }).catch(() => 0)
  const evs = await vault.outbox.query({ kinds: NOTE_KINDS, authors: [pubkey], until, limit })
  return evs.sort((a, b) => b.created_at - a.created_at)
}

/** Your own notes and reposts from the network into Haven's outbox (`kinds`: one of them). syncOwn fetches no
 *  reposts, so the opening load asks for them here, as deep as its 300 notes. -> how many were stored */
export async function syncOwnPage(vault, pubkey, relays, { until, limit = PERSON_PAGE, kinds = NOTE_KINDS, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq(relays), { kinds, authors: [pubkey], limit, ...(until ? { until } : {}) }, { maxWait: 8000 })
  let stored = 0
  for (const ev of evs) if (ev.pubkey === pubkey && kinds.includes(ev.kind) && (await vault.outbox.event(ev)).ok) stored++
  return stored
}

/** Their page on Brainstorm, the web's trust explorer (NostrWebLink.swift profile link). */
export const brainstormLink = pubkey => `https://brainstorm.world/p/${nprofileEncode({ pubkey })}`
