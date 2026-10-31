// New posts on Following from a live subscription, as on the iPhone (FeedService+FeedSubscription.swift keeps the feed
// REQ open after EOSE), not a sync every two minutes. One REQ per 250 follows on the read relays, from now on: each note
// that arrives is a follow's feed kind, is saved to Haven /feed as a sync would save it, and is handed on in batches,
// so a burst draws once. When every relay has closed the subscription (asleep, offline), it opens again after
// RETRY_MS and the caller syncs what was missed.
import { pool } from "./pool.js"
import { FEED_KINDS, storeAll } from "./sync.js"

export const LIVE_BATCH_MS = 1500
export const LIVE_RETRY_MS = 30_000
const AUTHORS_PER_REQ = 250

/**
 * Opens the subscription. `onNotes(saved)`: notes newly saved to /feed, once per batch. `onReopen()`: the subscription
 * dropped and has been opened again, so whatever came in between needs a sync. `since` is for tests.
 * -> close()
 */
export function watchFollowing({ vault, follows, relays, onNotes, onReopen = () => {}, since = Math.floor(Date.now() / 1000),
  subscribe = (urls, filter, params) => pool.subscribeMany(urls, filter, params), batchMs = LIVE_BATCH_MS, retryMs = LIVE_RETRY_MS,
  setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  const authors = new Set(follows)
  const seen = new Set()
  let batch = [], flushAt = null, retry = null, subs = [], stopped = false
  const flush = async () => {
    flushAt = null
    const evs = batch
    batch = []
    if (stopped || !evs.length) return
    try {
      const n = await storeAll(vault.feed, evs)
      if (n && !stopped) onNotes(evs)
    } catch {}
  }
  const take = ev => {
    if (stopped || !ev?.id || seen.has(ev.id) || !authors.has(ev.pubkey) || !FEED_KINDS.includes(ev.kind)) return
    seen.add(ev.id)
    batch.push(ev)
    if (!flushAt) { flushAt = setTimer(flush, batchMs); flushAt?.unref?.() }
  }
  const open = from => {
    let closed = 0
    const list = [...authors]
    const chunks = []
    for (let i = 0; i < list.length; i += AUTHORS_PER_REQ) chunks.push(list.slice(i, i + AUTHORS_PER_REQ))
    subs = chunks.map(chunk => subscribe(relays, { kinds: FEED_KINDS, authors: chunk, since: from }, {
      onevent: take,
      // Every relay closed this one. Once all have closed, open again later and let the caller catch up.
      onclose: () => {
        if (stopped || ++closed < chunks.length || retry) return
        retry = setTimer(() => { retry = null; if (stopped) return; open(Math.floor(Date.now() / 1000) - 60); onReopen() }, retryMs)
        retry?.unref?.()
      },
    }))
  }
  if (authors.size) open(since)
  return () => {
    stopped = true
    if (flushAt) clearTimer(flushAt)
    if (retry) clearTimer(retry)
    for (const s of subs) s.close()
  }
}
