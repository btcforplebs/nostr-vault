// Up Next (the iPhone's NowPlayingView queue): the songs after this one, "Shuffled" when shuffle is on, and a tap plays
// that song now. With nothing after this song it says so, or that the queue starts over under repeat all.
import * as wl from "./wavlake.js"
import { jump, upNext } from "./player.js"

export function UpNext({ state }) {
  const upcoming = upNext(state)
  return (
    <section class="music-upnext" aria-label="Up Next">
      <div class="music-upnext-head"><strong>Up Next</strong>{state.shuffled && <span class="music-upnext-shuffled small">Shuffled</span>}</div>
      {!upcoming.length
        ? <p class="muted small">{state.repeat === "all" ? "The queue starts over after this song." : "Nothing after this song."}</p>
        : <ol class="music-upnext-list">{upcoming.map(({ track: t, position }) => (
            <li key={`${position}-${t.id}`}>
              <button type="button" class="music-track" onClick={() => jump(position)} aria-label={`Play ${t.title} by ${t.artist} now`}>
                {t.art ? <img src={t.art} alt="" loading="lazy" referrerpolicy="no-referrer" /> : <div class="music-art small" />}
                <span class="music-track-text"><span class="music-track-title">{t.title}</span><span class="muted small">{t.artist}</span></span>
                <span class="muted small">{wl.clock(t.duration)}</span>
              </button>
            </li>
          ))}</ol>}
    </section>
  )
}
