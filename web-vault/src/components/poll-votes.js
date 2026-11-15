// A poll's votes (NIP-88 kind 1018): read from the poll's own public relays and yours, and sent the same way. Shared
// by the feed card (FeedKinds.jsx PollBody) and the Reader napplet's poll (napplet/kind-cards.js), so both count the
// same votes and a vote cast in one shows in the other.
import { pool } from "../net/pool.js"
import { verifiedCopy } from "../net/thread.js"
import { publishAction } from "../net/actions.js"
import { pollRelays, voteTags, VOTE_KIND } from "./polls.js"

// The votes on each poll this session, so a poll scrolled back to shows its count at once (PollStore).
const votes = new Map() // poll id -> { events: Map, at }
const RELOAD_AFTER_MS = 30_000

/** The votes held for a poll (none read yet: []). */
export const heldVotes = pollId => [...(votes.get(pollId)?.events.values() ?? [])]
/** Read less than RELOAD_AFTER_MS ago: no need to ask again. */
export const votesFresh = pollId => { const held = votes.get(pollId); return !!held && Date.now() - held.at < RELOAD_AFTER_MS }

/** Ask the poll's relays (and `readRelays`) for its votes, keep the signed ones. -> the votes held after. Never throws. */
export async function loadVotes(poll, readRelays = []) {
  const relays = pollRelays(poll, readRelays)
  if (!relays.length) return heldVotes(poll.id)
  try {
    const found = await pool.querySync(relays, { kinds: [VOTE_KIND], "#e": [poll.id], limit: 1000 }, { maxWait: 6000 })
    const store = votes.get(poll.id) ?? { events: new Map(), at: 0 }
    for (const ev of found) if (ev?.kind === VOTE_KIND && verifiedCopy(ev)) store.events.set(ev.id, ev)
    store.at = Date.now()
    votes.set(poll.id, store)
  } catch {}
  return heldVotes(poll.id)
}

/** Voting (PollModel.vote): a kind 1018 with the picks, signed by your signer, sent to your write relays and the
 *  poll's own public ones, and counted at once. -> the signed vote. Throws what publishAction throws. */
export async function sendVote(ctx, poll, ids) {
  // The poll's own public relays, deduplicated and at most 8 (the read path's set): a stranger's poll must not
  // choose how many hosts get your signed vote and your IP.
  const pub = pollRelays(poll)
  const template = { kind: VOTE_KIND, created_at: Math.floor(Date.now() / 1000), content: "", tags: voteTags(poll, ids, pub[0] ?? "") }
  const { event } = await publishAction(ctx, template)
  if (pub.length) Promise.allSettled(pool.publish(pub, event)).catch(() => {})
  const store = votes.get(poll.id) ?? { events: new Map(), at: Date.now() }
  store.events.set(event.id, event); votes.set(poll.id, store)
  return event
}
