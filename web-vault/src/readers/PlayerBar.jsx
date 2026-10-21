// The Music player bar (the iPhone's MiniPlayerBar plus the Now Playing controls): the song playing with its artist
// and album as links, a seek bar with elapsed and total time, shuffle, previous / play-pause / next, repeat
// (off, all, one), its Wavlake page, and ✕ to stop the music and hide the bar.
import { useEffect, useState } from "preact/hooks"
import * as wl from "./wavlake.js"
import { current, cycleRepeat, hasNext, next, onPlayer, playerState, previous, seek, stop, toggle, toggleShuffle } from "./player.js"

const REPEAT_LABEL = { off: "Repeat off", all: "Repeat all", one: "Repeat one" }

/** Line icons in the bar's text colour, so shuffle and repeat match the other controls (emoji draw as coloured tiles). */
const Glyph = ({ d, one = false }) => (
  <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={d} />{one && <text x="12" y="15.5" font-size="10" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none">1</text>}
  </svg>
)
const SHUFFLE = "M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5"
const REPEAT = "M17 1l4 4-4 4M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4M21 13v2a4 4 0 0 1-4 4H3"

/** `onOpen`: open the artist or album page ({ type, artist } / { type, album }), when the bar sits in Music. */
export function PlayerBar({ onOpen }) {
  const [s, setS] = useState(playerState)
  useEffect(() => onPlayer(setS), [])
  const t = current(s)
  if (!t) return null
  const total = s.duration || t.duration || 0
  const artist = t.artistId && onOpen ? () => onOpen({ type: "artist", artist: { id: t.artistId, name: t.artist, art: t.artistArt, npub: t.artistNpub } }) : null
  const album = t.albumId && onOpen ? () => onOpen({ type: "album", album: { id: t.albumId, title: t.albumTitle ?? "Album", art: t.art, artist: t.artist, artistId: t.artistId, year: null } }) : null
  return (
    <div class="music-player" role="region" aria-label="Now playing">
      <div class="music-player-row">
        {t.art ? <img src={t.art} alt="" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
        <div class="music-track-text">
          <span class="music-track-title">{album ? <button type="button" class="link" onClick={album} title={t.albumTitle ?? ""}>{t.title}</button> : t.title}</span>
          <span class="muted small">{s.error || (artist ? <button type="button" class="link" onClick={artist}>{t.artist}</button> : t.artist)}</span>
        </div>
        <a class="small" href={wl.trackPage(t.id)} target="_blank" rel="noopener noreferrer" aria-label="Open on Wavlake">↗</a>
        <button type="button" class="icon" onClick={stop} aria-label="Stop and close the player">✕</button>
      </div>
      <div class="music-seek">
        <span class="muted small">{wl.clock(s.time)}</span>
        <input type="range" min="0" max={total || 0} step="1" value={Math.min(s.time, total || 0)} disabled={!total}
          onInput={e => seek(Number(e.currentTarget.value))} aria-label="Seek" />
        <span class="muted small">{total ? wl.clock(total) : "--:--"}</span>
      </div>
      <div class="music-controls">
        <button type="button" class={`icon ${s.shuffled ? "on" : ""}`} onClick={() => toggleShuffle()} aria-pressed={s.shuffled} aria-label="Shuffle" title="Shuffle"><Glyph d={SHUFFLE} /></button>
        <button type="button" class="icon" onClick={previous} aria-label="Previous">⏮</button>
        <button type="button" class="icon play" onClick={toggle} aria-label={s.playing ? "Pause" : "Play"}>{s.playing ? "⏸" : "▶"}</button>
        <button type="button" class="icon" onClick={next} aria-label="Next" disabled={!hasNext(s)}>⏭</button>
        <button type="button" class={`icon ${s.repeat !== "off" ? "on" : ""}`} onClick={cycleRepeat} aria-label={REPEAT_LABEL[s.repeat]} title={REPEAT_LABEL[s.repeat]}><Glyph d={REPEAT} one={s.repeat === "one"} /></button>
      </div>
    </div>
  )
}
