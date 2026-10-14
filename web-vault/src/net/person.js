// Someone else's profile: their relay list, follow list and notes. Notes come from their NIP-65 write relays (where
// they publish) into Haven /feed, and the screen reads them back from there, so once you follow them the Following
// feed already has them.
import { pool, relayLists, DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "./pool.js"
import { newestList } from "./follows.js"

export const PERSON_PAGE = 50
const newest = evs => evs.reduce((a, e) => (!a || e.created_at > a.created_at ? e : a), undefined)

/** Their kind 10002 and kind 3 from the user's read relays and the index relays. -> { relays: {read, write}, contacts } */
export async function fetchPersonLists(pubkey, hintRelays, { query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...hintRelays, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { kinds: [3, 10002], authors: [pubkey] }, { maxWait: 6000 })
  const mine = evs.filter(e => e.pubkey === pubkey)
  return { relays: relayLists(newest(mine.filter(e => e.kind === 10002))), contacts: newestList(mine, pubkey) }
}

/** Their notes as Haven /feed has them, newest first. */
export async function readPersonNotes(vault, pubkey, { limit = PERSON_PAGE, until } = {}) {
  const evs = await vault.feed.query({ kinds: [1], authors: [pubkey], limit, ...(until ? { until } : {}) })
  return evs.filter(e => e.pubkey === pubkey).sort((a, b) => b.created_at - a.created_at)
}

/** One page of their notes (before `until`, if set) from their write relays into Haven /feed. -> notes the network had */
export async function syncPersonNotes(vault, pubkey, writeRelays, { until, limit = PERSON_PAGE, query = (r, f, o) => pool.querySync(r, f, o) } = {}) {
  const evs = await query(uniq([...writeRelays, ...DEFAULT_RELAYS]), { kinds: [1], authors: [pubkey], limit, ...(until ? { until } : {}) }, { maxWait: 8000 })
  const theirs = evs.filter(e => e.pubkey === pubkey && e.kind === 1)
  for (const ev of theirs) await vault.feed.event(ev)
  return theirs.length
}
