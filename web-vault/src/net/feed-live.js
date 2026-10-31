// New posts from live subscriptions, as on the iPhone (FeedService+FeedSubscription.swift keeps the feed REQ open after
// EOSE), not a poll. Following: one REQ per 250 follows on the read relays, from now on; each note that arrives is a
// follow's feed kind, is saved to Haven /feed as a sync would save it, and is handed on in batches, so a burst draws
// once. Global, Hashtag and Discover (FeedScreen) keep their own filters open the same way and save nothing. When every
// relay has closed the subscription (asleep, offline), it opens again after RETRY_MS and the caller fetches what was
// missed.
import { pool } from "./pool.js"
import { FEED_KINDS, storeAll } from "./sync.js"

export const LIVE_BATCH_MS = 1500
export const LIVE_RETRY_MS = 30_000
const AUTHORS_PER_REQ = 250

/**
 * Keeps `filters` open on `relays` (one REQ each), each from `since`. Each event `keep` accepts, once, joins a batch;
 * `save(evs)` (optional) stores a batch and says how many were new; `onNotes(evs)` gets each batch with something new.
 * `onReopen()`: every REQ dropped and has been opened again from about now, so whatever came in between needs fetching.
 * -> close()
 */
export function watchLive({ filters, relays, keep = () => true, save = null, onNotes, onReopen = () => {}, since = Math.floor(Date.now() / 1000),
  subscribe = (urls, filter, params) => pool.subscribeMany(urls, filter, params), batchMs = LIVE_BATCH_MS, retryMs = LIVE_RETRY_MS,
  setTimer = setTimeout, clearTimer = clearTimeout }) {
  const seen = new Set()
  let batch = [], flushAt = null, retry = null, subs = [], stopped = false
  const flush = async () => {
    flushAt = null
    const evs = batch
    batch = []
    if (stopped || !evs.length) return
    try {
      const n = save ? await save(evs) : evs.length
      if (n && !stopped) onNotes(evs)
    } catch {}
  }
  const take = ev => {
    if (stopped || !ev?.id || seen.has(ev.id) || !keep(ev)) return
    seen.add(ev.id)
    batch.push(ev)
    if (!flushAt) { flushAt = setTimer(flush, batchMs); flushAt?.unref?.() }
  }
  const open = from => {
    let closed = 0
    subs = filters.map(f => subscribe(relays, { ...f, since: from }, {
      onevent: take,
      // Every relay closed this one. Once all have closed, open again later and let the caller catch up.
      onclose: () => {
        if (stopped || ++closed < filters.length || retry) return
        retry = setTimer(() => { retry = null; if (stopped) return; open(Math.floor(Date.now() / 1000) - 60); onReopen() }, retryMs)
        retry?.unref?.()
      },
    }))
  }
  if (filters.length) open(since)
  return () => {
    stopped = true
    if (flushAt) clearTimer(flushAt)
    if (retry) clearTimer(retry)
    for (const s of subs) s.close()
  }
}

/** Following: one REQ per 250 follows, for the feed's kinds; each follow's note is saved to Haven /feed as a sync
 *  would save it, and `onNotes` gets the batches that saved something. */
export function watchFollowing({ vault, follows, ...rest }) {
  const authors = new Set(follows), list = [...authors]
  const filters = []
  for (let i = 0; i < list.length; i += AUTHORS_PER_REQ) filters.push({ kinds: FEED_KINDS, authors: list.slice(i, i + AUTHORS_PER_REQ) })
  return watchLive({ ...rest, filters, keep: ev => authors.has(ev.pubkey) && FEED_KINDS.includes(ev.kind), save: evs => storeAll(vault.feed, evs) })
}
