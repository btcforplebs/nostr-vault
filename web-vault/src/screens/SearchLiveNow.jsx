// Live now at the top of Search (Logen, 2026-11-04; the iPhone's Views/Search/SearchLiveNowSection.swift): people you
// follow who are on air, with picture, name and stream title. A click opens the stream's player over everything
// (LiveEmbed.jsx LiveSheet). Same ask and rules as the Your space panel (desktop/space/live-now.js). It asks while
// Search's start page shows, again every two minutes, draws nothing when nobody is live, and publishes nothing.
import { useEffect, useMemo, useState } from "preact/hooks"
import { Avatar } from "../components/Avatar.jsx"
import { AuthorName } from "../components/NoteCard.jsx"
import { lookInFront } from "../components/auto-look.js"
import { fetchProfiles } from "../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../net/pool.js"
import { LiveSheet } from "../readers/LiveEmbed.jsx"
import { liveNow, rowsOf, REFRESH_MS } from "../desktop/space/live-now.js"
import "../styles/live-now.css"

/** Your follows' live streams, asked now and every REFRESH_MS while mounted. [] until the first answer. */
export function useLiveNow(ctx, blocked) {
  const me = ctx.session.pubkey
  const follows = useMemo(() => ctx.account.follows.filter(pk => pk !== me), [ctx.account.follows, me])
  const [streams, setStreams] = useState([])
  useEffect(() => {
    if (!follows.length) { setStreams([]); return }
    let live = true
    const look = () => liveNow({ me, follows, readRelays: ctx.account.relays.read, blocked })
      .then(list => {
        if (!live) return
        setStreams(list)
        if (list.length) fetchProfiles(ctx.vault, list.map(s => s.host), uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { save: false }).catch(() => {})
      })
      .catch(() => {})
    look()
    const stop = lookInFront(look, { every: REFRESH_MS })
    return () => { live = false; stop() }
  }, [me, follows.length, follows[0], blocked?.size])
  return streams
}

/** The section. Nothing when nobody is live. */
export function SearchLiveNow({ ctx, streams }) {
  const [playing, setPlaying] = useState(null)
  const { rows, more } = rowsOf(streams)
  if (!rows.length) return null
  return (
    <section class="search-live" aria-label="Live now">
      <div class="section-label"><span class="search-live-dot" aria-hidden="true" />Live now</div>
      {rows.map(s => (
        <button key={s.address} type="button" class="person-row search-live-row" onClick={() => setPlaying(s)} title={s.title || "Open the stream"}>
          <Avatar pubkey={s.host} />
          <span class="person-names">
            <span class="author-name"><AuthorName pubkey={s.host} /></span>
            <span class="person-sub">{s.title || "Live now"}</span>
          </span>
          <span class="ln-badge">LIVE</span>
        </button>
      ))}
      {more > 0 && <div class="section-label search-live-more">+{more} more live</div>}
      {playing && <LiveSheet ctx={ctx} stream={playing} onClose={() => setPlaying(null)} />}
    </section>
  )
}
