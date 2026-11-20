// Live now, a "Your space" panel (LiveNow.jsx): streams (NIP-53 kind 30311) from people you follow that are on air,
// newest first. The rules are the Live feed's Following (live.js pickStreams): the newest event per address wins, the
// author or the Host must be followed, a block on either hides it, and only an on-air HLS stream counts. The iPad's twin
// is HavenApp/Models/LiveNow.swift. Nothing is saved: a stream only matters while it runs.
import { liveFilters, liveRelays, pickStreams, parseStream, STALE_AFTER } from "../../readers/live.js"
import { pool } from "../../net/pool.js"

/** The panel's id in the synced layout, shared with the iPad. Never rename. */
export const LIVE_NOW_ID = "live-now"
/** Rows drawn; the rest are a "+N more live" line. */
export const MAX_ROWS = 5
/** How often an open panel asks again: streams start at any time. */
export const REFRESH_MS = 2 * 60 * 1000

/** The calm line drawn when nobody is live. */
export const emptyLine = followsSomeone =>
  followsSomeone ? "Nobody you follow is live right now." : "Follow people to see when they go live."

/** How far a repeat look reaches back before the last one: a relay may store an event a little after its created_at. */
export const OVERLAP = 60

/** What the looks so far have kept: per account, follows and relays, the newest stream event per address and when it
 *  was last asked. A repeat look asks only for events since then (it used to re-ask every relay for every follow's
 *  streams every two minutes: ~3 MB a round, ~100 MB an hour on an idle desktop, perf audit 2026-11-20 W4). Shared by
 *  the panel, its napplet card and Search, which ask the same thing. */
const held = new Map()
const MAX_HELD = 4

/** Forget what was kept (tests). */
export const forgetLiveNow = () => held.clear()

/** One look. `query` and `now` are for tests. -> streams ([] when you follow nobody). The first look asks for the last
 *  STALE_AFTER (an older announcement can't be on air), each repeat only since the last look, merged with what is held. */
export async function liveNow({ me, follows, readRelays, blocked, query = (r, f, o) => pool.querySync(r, f, o), now }) {
  const filters = liveFilters("following", follows)
  if (!filters.length) return []
  const at = now ?? Math.floor(Date.now() / 1000)
  const key = `${me}|${[...readRelays].sort().join(",")}|${[...follows].sort().join(",")}`
  let h = held.get(key)
  if (!h) {
    if (held.size >= MAX_HELD) held.delete(held.keys().next().value)
    h = { last: null, byAddress: new Map() }
    held.set(key, h)
  }
  const since = h.last == null ? at - STALE_AFTER - OVERLAP : h.last - OVERLAP
  await Promise.all(filters.map(async f => {
    for (const ev of await query(liveRelays(readRelays), { ...f, since }, { maxWait: 10000 })) {
      const s = parseStream(ev)
      const have = s && h.byAddress.get(s.address)
      if (s && (!have || ev.created_at > have.created_at)) h.byAddress.set(s.address, ev)
    }
  }))
  h.last = at
  for (const [address, ev] of h.byAddress) if (at - ev.created_at > STALE_AFTER) h.byAddress.delete(address)
  return pickStreams([...h.byAddress.values()], { scope: "following", follows, blocked, now: at })
}

/** What the panel draws: the first MAX_ROWS and how many more. */
export const rowsOf = streams => ({ rows: streams.slice(0, MAX_ROWS), more: Math.max(0, streams.length - MAX_ROWS) })
