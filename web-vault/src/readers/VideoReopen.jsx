// "Back to the video": the minimized clip opens full screen again at the player's time, with sound, and the player
// lets it go in the same step (as LiveScreen stops the bar's copy of a stream it opens again). It opens in the note
// lightbox (components/MediaLightbox.jsx) whichever screen it came from, so it works from any player bar; Minimize
// there hands it back. A DM video's blob: URL is held while the viewer is up (blob-hold.js).
import { useEffect, useState } from "preact/hooks"
import { MediaLightbox } from "../components/MediaLightbox.jsx"
import { holdBlob, releaseBlob } from "./blob-hold.js"
import { current, element, playerState, stop } from "./player.js"

let open = null // { url, at, meta } while the viewer is up
const listeners = new Set()
const changed = () => { for (const f of listeners) f(open) }

/** The clip `open` would show for the player's state, or null when the player isn't playing a video. */
export function reopenOf(s = playerState()) {
  const t = current(s)
  if (!t?.video) return null
  return { url: t.mediaUrl, at: s.time || 0, meta: { title: t.title, artist: t.artist, author: t.author, art: t.art } }
}

/** Opens the minimized video again and stops the player. */
export function backToVideo(s = playerState()) {
  const v = reopenOf(s)
  if (!v) return false
  // The bar's state.time comes from timeupdate, a few times a second; the element itself is exact.
  if (s === playerState() && element().currentTime > 0) v.at = element().currentTime
  holdBlob(v.url) // before stop() lets the player's hold go
  stop()
  if (open) releaseBlob(open.url) // one viewer at a time: the one it replaces lets its hold go
  open = v; changed()
  return true
}

/** For tests: what is open. */
export const reopened = () => open

export function closeReopened() {
  if (!open) return
  releaseBlob(open.url)
  open = null; changed()
}

/** Mounted once, app-wide (FloatingPlayer). */
export function ReopenedVideo() {
  const [v, setV] = useState(open)
  useEffect(() => { listeners.add(setV); setV(open); return () => listeners.delete(setV) }, [])
  if (!v) return null
  return <MediaLightbox key={`${v.url}@${v.at}`} items={[{ type: "video", url: v.url, at: v.at, sound: true, meta: v.meta }]}
    author={v.meta.author} onClose={closeReopened} />
}
