// Live now, a "Your space" panel (LiveNow.jsx): streams (NIP-53 kind 30311) from people you follow that are on air,
// newest first. The rules are the Live feed's Following (live.js pickStreams): the newest event per address wins, the
// author or the Host must be followed, a block on either hides it, and only an on-air HLS stream counts. The iPad's twin
// is HavenApp/Models/LiveNow.swift. Nothing is saved: a stream only matters while it runs.
import { fetchStreams } from "../../readers/live.js"

/** The panel's id in the synced layout, shared with the iPad. Never rename. */
export const LIVE_NOW_ID = "live-now"
/** Rows drawn; the rest are a "+N more live" line. */
export const MAX_ROWS = 5
/** How often an open panel asks again: streams start at any time. */
export const REFRESH_MS = 2 * 60 * 1000

/** The calm line drawn when nobody is live. */
export const emptyLine = followsSomeone =>
  followsSomeone ? "Nobody you follow is live right now." : "Follow people to see when they go live."

/** One look. `query` and `now` are for tests. -> streams ([] when you follow nobody). */
export async function liveNow({ me, follows, readRelays, blocked, query, now }) {
  return (await fetchStreams({ scope: "following", me, follows, readRelays, blocked, query, now })) ?? []
}

/** What the panel draws: the first MAX_ROWS and how many more. */
export const rowsOf = streams => ({ rows: streams.slice(0, MAX_ROWS), more: Math.max(0, streams.length - MAX_ROWS) })
