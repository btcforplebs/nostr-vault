// The Catch Up feed, as the iPhone and Android build it (haven-go feed_catchup.go): the newest post of each person you
// follow, newest first. One post per person, so a quiet friend's one post this week sits next to a busy account's
// latest instead of under its fifty. Notes (not replies) and articles from the last 14 days.
// Haven /feed is read first, a few posts per person; only the people with nothing there are asked of the relays, in
// REQs of 250. What the relays send is held in memory with the page: nothing is written to /feed (the Go feed writes
// nothing either). The pool checks each relay event's id and signature before it gets here (pool.js).
import { pool, uniq } from "./pool.js"

export const WINDOW = 14 * 24 * 3600 // seconds back a person's latest post may be (catchUpWindow)
export const PER_AUTHOR = 8 // posts read per person from /feed, to step over a few replies (catchUpPerAuthor)
export const MAX_NOTES = 500 // most people one Catch Up lists (catchUpMaxNotes)
export const FETCH_BATCH = 250 // authors per relay REQ (catchUpFetchBatch)
export const MAX_SKEW = 600 // a post dated this far ahead still shows (popularMaxClockSkew)
export const KINDS = [1, 30023] // notes and articles (catchUpKinds)
const READS_AT_ONCE = 16 // per-person /feed reads in flight at a time
const HEX = /^[0-9a-f]{64}$/

/** A reply, as haven-go isReplyNote reads one: any `e` tag not marked "mention". */
export const isReplyNote = ev => (ev.tags ?? []).some(t => t[0] === "e" && t.length >= 2 && !(t.length >= 4 && t[3] === "mention"))

/** Lowercased hex pubkeys, junk dropped, each once, order kept (normalizeFollows). */
export function normalizeFollows(follows) {
  const out = new Set()
  for (const pk of follows ?? []) {
    const k = String(pk ?? "").trim().toLowerCase()
    if (HEX.test(k)) out.add(k)
  }
  return [...out]
}

/** For each wanted author, their newest post that is not a reply, inside the window and not dated in the future;
 *  newest first, ties on id so the order is total, at most MAX_NOTES (pickLatestPerAuthor). */
export function pickLatestPerAuthor(events, wanted, now = Math.floor(Date.now() / 1000)) {
  const since = now - WINDOW, ahead = now + MAX_SKEW
  const best = new Map()
  for (const ev of events) {
    if (!ev || !wanted.has(ev.pubkey) || !KINDS.includes(ev.kind)) continue
    const at = ev.created_at
    if (at < since || at > ahead || (ev.kind === 1 && isReplyNote(ev))) continue
    const cur = best.get(ev.pubkey)
    if (!cur || at > cur.created_at || (at === cur.created_at && ev.id < cur.id)) best.set(ev.pubkey, ev)
  }
  return [...best.values()].sort((a, b) => b.created_at - a.created_at || (a.id < b.id ? -1 : 1)).slice(0, MAX_NOTES)
}

/** Each author's newest posts from Haven /feed, PER_AUTHOR each (queryLocalPerAuthor). A failed read is skipped. */
async function readLocal(vault, authors, since) {
  const out = []
  for (let i = 0; i < authors.length; i += READS_AT_ONCE) {
    const reads = authors.slice(i, i + READS_AT_ONCE)
      .map(pk => vault.feed.query({ kinds: KINDS, authors: [pk], since, limit: PER_AUTHOR }).catch(() => []))
    for (const evs of await Promise.all(reads)) out.push(...evs)
  }
  return out
}

/**
 * The Catch Up page for these follows: one post per person, newest first. `query` is for tests.
 */
export async function fetchCatchUp({ follows, relays, vault, now = Math.floor(Date.now() / 1000), query = (r, f, o) => pool.querySync(r, f, o) }) {
  const authors = normalizeFollows(follows)
  if (!authors.length) return []
  const wanted = new Set(authors), since = now - WINDOW
  const events = vault ? await readLocal(vault, authors, since) : []
  const have = new Set(pickLatestPerAuthor(events, wanted, now).map(n => n.pubkey))
  const missing = authors.filter(pk => !have.has(pk))
  const urls = uniq(relays ?? [])
  if (missing.length && urls.length) {
    const asks = []
    for (let i = 0; i < missing.length; i += FETCH_BATCH)
      asks.push(query(urls, { kinds: KINDS, authors: missing.slice(i, i + FETCH_BATCH), since, limit: 500 }, { maxWait: 12000 }).catch(() => []))
    for (const evs of await Promise.all(asks)) events.push(...evs)
  }
  return pickLatestPerAuthor(events, wanted, now)
}
