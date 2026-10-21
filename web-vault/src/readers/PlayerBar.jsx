// The Music player bar (the iPhone's MiniPlayerBar): the song playing, its controls and its Wavlake page.
import { useEffect, useState } from "preact/hooks"
import * as wl from "./wavlake.js"
import { current, onPlayer, playerState, previous, next, toggle } from "./player.js"

/** The song playing: cover, title and artist, previous / play-pause / next, time, and its Wavlake page. */
export function PlayerBar() {
  const [s, setS] = useState(playerState)
  useEffect(() => onPlayer(setS), [])
  const t = current(s)
  if (!t) return null
  return (
    <div class="music-player" role="region" aria-label="Now playing">
      {t.art ? <img src={t.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
      <div class="music-track-text"><span class="music-track-title">{t.title}</span><span class="muted small">{s.error || `${t.artist} · ${wl.clock(s.time)}${s.duration ? ` / ${wl.clock(s.duration)}` : ""}`}</span></div>
      <button type="button" class="icon" onClick={previous} aria-label="Previous">⏮</button>
      <button type="button" class="icon" onClick={toggle} aria-label={s.playing ? "Pause" : "Play"}>{s.playing ? "⏸" : "▶"}</button>
      <button type="button" class="icon" onClick={next} aria-label="Next" disabled={s.index + 1 >= s.queue.length}>⏭</button>
      <a class="small" href={wl.trackPage(t.id)} target="_blank" rel="noopener noreferrer" aria-label="Open on Wavlake">↗</a>
    </div>
  )
}
