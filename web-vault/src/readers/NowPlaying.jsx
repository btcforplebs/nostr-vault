// Now Playing, full screen (the iPhone's NowPlayingView): the cover blown up and blurred behind, the cover, title,
// artist and album as links into Music, a seek bar with times, shuffle / previous / play-pause / next / repeat, Up Next,
// and the song's Wavlake page. A minimized live stream shows LIVE, play/pause and a way back to its window instead.
// Escape or ⌄ closes it.
import { useEffect, useRef, useState } from "preact/hooks"
import { AuthorName } from "../components/NoteCard.jsx"
import * as wl from "./wavlake.js"
import { UpNext } from "./UpNext.jsx"
import { ArtistZap } from "./ArtistZap.jsx"
import { DOWN, Glyph, QUEUE, REPEAT, REPEAT_LABEL, SHUFFLE } from "./PlayerIcons.jsx"
import { current, cycleRepeat, hasNext, next, previous, seek, stop, toggle, toggleShuffle } from "./player.js"

/** The pages the artist and album links open: { artist } / { album } in the shape MusicScreen's pages take. */
export function pagesOf(t) {
  return {
    artist: t.artistId ? { type: "artist", artist: { id: t.artistId, name: t.artist, art: t.artistArt ?? null, npub: t.artistNpub ?? null } } : null,
    album: t.albumId ? { type: "album", album: { id: t.albumId, title: t.albumTitle ?? "Album", art: t.art, artist: t.artist, artistId: t.artistId ?? null, year: null } } : null,
  }
}

export function NowPlaying({ state: s, onClose, onOpen, onOpenLive }) {
  const t = current(s)
  const [queue, setQueue] = useState(false)
  const box = useRef(null)
  useEffect(() => {
    box.current?.focus()
    const key = e => { if (e.key === "Escape") onClose() }
    addEventListener("keydown", key)
    return () => removeEventListener("keydown", key)
  }, [])
  if (!t) return null
  const total = s.duration || t.duration || 0
  const { artist, album } = pagesOf(t)
  return (
    <div class="now-playing" role="dialog" aria-modal="true" aria-label="Now Playing" tabindex="-1" ref={box}>
      {t.art && <img class="now-playing-backdrop" src={t.art} alt="" aria-hidden="true" referrerpolicy="no-referrer" />}
      <div class="now-playing-body">
        <div class="now-playing-top">
          <button type="button" class="icon" onClick={onClose} aria-label="Close Now Playing"><Glyph d={DOWN} size={26} /></button>
          <span class="muted small">{t.live ? "Live stream" : "Now Playing"}</span>
          {t.live ? <span class="now-playing-spacer" /> : <a class="small" href={wl.trackPage(t.id)} target="_blank" rel="noopener noreferrer" aria-label="Open on Wavlake">Wavlake ↗</a>}
        </div>
        {t.art ? <img class="now-playing-art" src={t.art} alt="" referrerpolicy="no-referrer" /> : <div class="now-playing-art music-art" />}
        <div class="now-playing-text">
          {t.live && <span class="music-live">LIVE</span>}
          <h2>{t.title}</h2>
          {artist && onOpen ? <button type="button" class="link" onClick={() => onOpen(artist)}>{t.artist} ›</button>
            : <p class="muted">{t.live && t.stream?.host ? <AuthorName pubkey={t.stream.host} /> : t.artist}</p>}
          {album && onOpen && t.albumTitle && <button type="button" class="link small muted" onClick={() => onOpen(album)}>{t.albumTitle} ›</button>}
          {s.error && <p class="error small" role="alert">{s.error}</p>}
        </div>
        {!t.live && (
          <div class="music-seek">
            <span class="muted small">{wl.clock(s.time)}</span>
            <input type="range" min="0" max={total || 0} step="1" value={Math.min(s.time, total || 0)} disabled={!total}
              onInput={e => seek(Number(e.currentTarget.value))} aria-label="Seek" />
            <span class="muted small">{total ? wl.clock(total) : "--:--"}</span>
          </div>
        )}
        <div class="music-controls now-playing-controls">
          {!t.live && <button type="button" class={`icon ${s.shuffled ? "on" : ""}`} onClick={() => toggleShuffle()} aria-pressed={s.shuffled} aria-label="Shuffle" title="Shuffle"><Glyph d={SHUFFLE} /></button>}
          {!t.live && <button type="button" class="icon" onClick={previous} aria-label="Previous">⏮</button>}
          <button type="button" class="icon play big" onClick={toggle} aria-label={s.playing ? "Pause" : "Play"}>{s.playing ? "⏸" : "▶"}</button>
          {!t.live && <button type="button" class="icon" onClick={next} aria-label="Next" disabled={!hasNext(s)}>⏭</button>}
          {!t.live && <button type="button" class={`icon ${s.repeat !== "off" ? "on" : ""}`} onClick={cycleRepeat} aria-label={REPEAT_LABEL[s.repeat]} title={REPEAT_LABEL[s.repeat]}><Glyph d={REPEAT} one={s.repeat === "one"} /></button>}
        </div>
        <div class="now-playing-actions">
          {t.live
            ? <>{onOpenLive && <button type="button" class="small" onClick={() => onOpenLive(t.stream)}>Back to the stream</button>}
                <button type="button" class="small" onClick={stop}>Stop</button></>
            : <><button type="button" class={`small ${queue ? "on" : ""}`} onClick={() => setQueue(!queue)} aria-pressed={queue}><Glyph d={QUEUE} size={16} /> Up Next</button>
                <ArtistZap track={t} /></>}
        </div>
        {queue && !t.live && <UpNext state={s} />}
      </div>
    </div>
  )
}
