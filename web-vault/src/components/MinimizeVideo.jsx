// Minimize on a video, as the live window's Minimize (readers/LiveScreen.jsx): the clip's sound carries on in the
// player bar from where it was (readers/player.js playVideo), and the video here pauses in the same step, so the two
// never play at once. The bar's "Back to the video" opens it again (readers/VideoReopen.jsx). Used by the lightbox,
// the Vault's big view, a note's inline video and a DM video.
import { useEffect, useRef, useState } from "preact/hooks"
import { playVideo } from "../readers/player.js"
import { barMounted, onBarMounted } from "../readers/bar-mounted.js"

/** Hands `v`'s clip to the player at its current time and pauses `v`. `url` is the URL `v` actually plays. */
export function minimizeVideo(v, url, meta = {}) {
  if (!v || !url) return false
  // A looping viewer is often just before its end: from there the bar would play a moment and vanish, so it starts over.
  const near = Number.isFinite(v.duration) && v.duration > 0 && v.duration - (v.currentTime || 0) < 1
  const at = near ? 0 : v.currentTime || 0
  v.pause()
  playVideo(url, at, meta)
  return true
}

/** The text button. `video`: a function giving the <video> element at the tap. `overlay`: drawn over the video's
 *  top-left corner (a note's or DM video); otherwise a plain small button in a row. `onDone`: after the hand-over,
 *  e.g. to close a full-screen viewer, as live's Minimize leaves its window. Not drawn where no player bar is mounted
 *  (bar-mounted.js): the sound would have no bar to stop it. */
export function MinimizeButton({ video, url, meta, onDone, overlay = false }) {
  const [bar, setBar] = useState(barMounted)
  useEffect(() => { setBar(barMounted()); return onBarMounted(setBar) }, [])
  const tap = e => {
    e.stopPropagation(); e.preventDefault()
    if (minimizeVideo(video(), url, meta)) onDone?.()
  }
  if (!bar) return null
  return (
    <button type="button" class={overlay ? "video-minimize overlay" : "small video-minimize"} onClick={tap}
      title="Keep its sound playing in the player while you browse">Minimize</button>
  )
}

/** A video link drawn where it stands in a note's text (NoteText, BlossomMedia), with Minimize over it. `author`: the
 *  note's pubkey, shown in the player bar. */
export function TextVideo({ src, author, ...attrs }) {
  const ref = useRef(null)
  return (
    <span class="video-min-box text">
      <video ref={ref} class="note-media" src={src} controls preload="metadata" playsinline {...attrs} />
      <MinimizeButton video={() => ref.current} url={src} meta={{ author }} overlay />
    </span>
  )
}
