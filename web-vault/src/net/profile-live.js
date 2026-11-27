// A profile's notes while it is on screen (profile perf review 2026-11-27, findings 2 and 6). New notes by the
// profile's owner arrive live, one subscription from now on (feed-live.js watchLive), so the page no longer looks
// again every 5 minutes; and your own profile, opened again or looked at again, asks the relays only for what came
// after the newest note it holds, not the whole first page from every write relay (1.5 MB a look).
import { watchLive } from "./feed-live.js"
import { NOTE_KINDS, SINCE_SLACK_S } from "./person.js"

// Accounts whose whole opening page was asked for in this page load. The first open asks for all of it (a note
// written elsewhere long ago may be missing from Haven); after that only what is newer.
const asked = new Set()

/** `since` for your own profile's opening ask: none on the first open of this page load, then just before the newest
 *  note held (`held`, newest first or not). */
export function ownSince(me, held) {
  if (!asked.has(me) || !held?.length) return undefined
  return Math.max(...held.map(e => e.created_at)) - SINCE_SLACK_S
}
/** The whole opening page has been asked for (ownSince asks only what is newer from now on). */
export const markOwnAsked = me => asked.add(me)
/** For the tests. */
export const forgetOwnAsked = () => asked.clear()

/**
 * Keeps one subscription for `pubkey`'s notes and reposts (NOTE_KINDS) open on `relays` from now on. `save(evs)`
 * (optional) stores a batch; `onNotes(evs)` gets each batch of their notes; `onReopen()` once every relay dropped it
 * and it opened again, so the caller asks for what came in between. -> close()
 */
export function watchProfile({ pubkey, relays, save = null, onNotes, onReopen, watch = watchLive, ...rest }) {
  return watch({
    ...rest,
    relays,
    filters: [{ kinds: NOTE_KINDS, authors: [pubkey] }],
    keep: ev => ev?.pubkey === pubkey && NOTE_KINDS.includes(ev.kind),
    save,
    onNotes: evs => onNotes(evs.filter(ev => ev.pubkey === pubkey)),
    onReopen,
  })
}
