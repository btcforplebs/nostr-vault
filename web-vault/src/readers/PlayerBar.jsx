// The player bar (the iPhone's MiniPlayerBar): cover, title and artist (a LIVE badge for a minimized stream),
// play/pause, next (songs only), ✕ to stop, and a progress line. Tapping it opens the full Now Playing.
import { useEffect, useState } from "preact/hooks"
import { AuthorName } from "../components/NoteCard.jsx"
import { NowPlaying } from "./NowPlaying.jsx"
import { current, hasNext, next, onPlayer, playerState, stop, toggle } from "./player.js"

/** `onOpen`: open an artist or album page in Music. `onOpenLive`: back to a minimized stream's full window. */
export function PlayerBar({ onOpen, onOpenLive }) {
  const [s, setS] = useState(playerState)
  const [full, setFull] = useState(false)
  useEffect(() => onPlayer(setS), [])
  const t = current(s)
  useEffect(() => { if (!t) setFull(false) }, [!!t])
  if (!t) return null
  const total = s.duration || t.duration || 0
  const progress = !t.live && total ? Math.min(1, s.time / total) : 0
  return (
    <>
      <div class="music-player mini" role="region" aria-label="Now playing">
        <button type="button" class="music-player-row music-open" onClick={() => setFull(true)} aria-label={`Open Now Playing: ${t.title}`}>
          {t.art ? <img src={t.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
          <span class="music-track-text">
            <span class="music-track-title">{t.title}</span>
            <span class="muted small">{t.live && <span class="music-live">LIVE</span>}{s.error || (t.live && t.stream?.host ? <AuthorName pubkey={t.stream.host} /> : t.artist)}</span>
          </span>
        </button>
        <button type="button" class="icon play" onClick={toggle} aria-label={s.playing ? "Pause" : "Play"}>{s.playing ? "⏸" : "▶"}</button>
        {!t.live && <button type="button" class="icon" onClick={next} aria-label="Next" disabled={!hasNext(s)}>⏭</button>}
        <button type="button" class="icon" onClick={stop} aria-label="Stop and close the player">✕</button>
        <span class="music-progress" aria-hidden="true"><span style={{ width: `${progress * 100}%` }} /></span>
      </div>
      {full && <NowPlaying state={s} onClose={() => setFull(false)} onOpen={onOpen && (p => { setFull(false); onOpen(p) })}
        onOpenLive={onOpenLive && (st => { setFull(false); onOpenLive(st) })} />}
    </>
  )
}
