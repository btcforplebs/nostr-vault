// Live now: a "Your space" panel. Streams (NIP-53) from people you follow that are on air, newest first (live-now.js).
// A click on a row opens the stream's player over everything, as a live stream inside a note does (LiveEmbed.jsx
// LiveSheet). Nobody live is one calm line, not an error. It asks again every two minutes while it is open, and
// publishes nothing.
import { useEffect, useMemo, useState } from "preact/hooks"
import { Avatar } from "../../components/Avatar.jsx"
import { AuthorName } from "../../components/NoteCard.jsx"
import { lookInFront } from "../../components/auto-look.js"
import { useBlocks } from "../../components/useBlocks.js"
import { fetchProfiles } from "../../net/profiles.js"
import { DEFAULT_RELAYS, PROFILE_RELAYS, uniq } from "../../net/pool.js"
import { LiveSheet } from "../../readers/LiveEmbed.jsx"
import { liveNow, rowsOf, emptyLine, REFRESH_MS } from "./live-now.js"
import "../../styles/live-now.css"

const DOT = "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM6.3 6.3a8 8 0 0 0 0 11.4M17.7 6.3a8 8 0 0 1 0 11.4"

export function LiveNow({ ctx, open = true, tools = null }) {
  const me = ctx.session.pubkey
  const follows = useMemo(() => ctx.account.follows.filter(pk => pk !== me), [ctx.account.follows, me])
  const { blocked } = useBlocks(ctx)
  const [streams, setStreams] = useState(null)
  const [playing, setPlaying] = useState(null)
  useEffect(() => {
    if (!open) return
    if (!follows.length) { setStreams([]); return }
    let live = true
    const look = () => liveNow({ me, follows, readRelays: ctx.account.relays.read, blocked })
      .then(list => {
        if (!live) return
        setStreams(list)
        if (list.length) fetchProfiles(ctx.vault, list.map(s => s.host), uniq([...ctx.account.relays.read, ...DEFAULT_RELAYS, ...PROFILE_RELAYS]), { save: false }).catch(() => {})
      })
      .catch(() => { if (live) setStreams(s => s ?? []) })
    look()
    const stop = lookInFront(look, { every: REFRESH_MS, on: open })
    return () => { live = false; stop() }
  }, [open, me, follows.length, follows[0], blocked.size])
  const { rows, more } = rowsOf(streams ?? [])
  const count = streams?.length ?? 0
  return (
    <section class={open ? "sp-panel live-now" : "sp-panel live-now closed"} aria-label="Live now">
      <header class="sp-head">
        <span class="sp-icon ln-icon"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d={DOT} /></svg></span>
        <h3>Live now</h3>
        {count > 0 && <span class="ln-count" role="img" aria-label={`${count} live`}>{count}</span>}
        {tools}
      </header>
      <ul class="sp-rows">
        {!ctx.account.loaded ? <li class="sp-empty">Loading your follows…</li>
          : streams === null ? <li class="sp-empty">Looking for live streams…</li>
          : !rows.length ? <li class="sp-empty">{emptyLine(follows.length > 0)}</li>
          : rows.map(s => <Row key={s.address} stream={s} onOpen={() => setPlaying(s)} />)}
        {more > 0 && <li class="sp-empty ln-more">+{more} more live</li>}
      </ul>
      {playing && <LiveSheet ctx={ctx} stream={playing} onClose={() => setPlaying(null)} />}
    </section>
  )
}

/** One stream: the host's face with a red ring, their name, the title, and LIVE. */
function Row({ stream: s, onOpen }) {
  return (
    <li>
      <button type="button" class="sp-row ln-row" onClick={onOpen} title={s.title || "Open the stream"}>
        <Avatar pubkey={s.host} size={32} />
        <span class="sp-row-main">
          <span class="sp-row-who"><AuthorName pubkey={s.host} /></span>
          <span class="sp-row-text">{s.title || "Live now"}</span>
        </span>
        <span class="sp-row-side"><span class="ln-badge">LIVE</span></span>
      </button>
    </li>
  )
}
