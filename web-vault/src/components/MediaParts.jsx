// Pieces NoteMedia and MediaLightbox share.
import { useEffect, useRef } from "preact/hooks"
import { reducedMotion } from "./pager.js"
import { autoplayOn } from "../net/media-prefs.js"
import { MinimizeButton } from "./MinimizeVideo.jsx"

/** A video in a note, as iOS InlineFeedVideoPlayer (FeedMediaView.swift): muted, looping, playing inline while it is
 *  on screen, with controls. No autoplay when the user asks for reduced motion or turned Autoplay Videos off
 *  (Settings › Media): the video waits for its play control. `minimize`: { meta, onDone? } draws a Minimize over it
 *  (MinimizeVideo.jsx). `sound` with `at`: a minimized clip opened again, playing with sound from `at` seconds. */
export function InlineVideo({ src, minimize = null, sound = false, at = 0 }) {
  const ref = useRef()
  useEffect(() => {
    const v = ref.current
    if (!v || !sound) return
    // Opened from the player bar: a tap asked for it, so it plays with sound whatever Autoplay says; a browser that
    // still refuses sound gets it muted, with the controls there.
    const go = () => {
      if (at > 0) v.currentTime = at
      v.muted = false
      v.play()?.catch?.(() => { v.muted = true; v.play()?.catch?.(() => {}) })
    }
    if (v.readyState >= 1) go(); else v.addEventListener("loadedmetadata", go, { once: true })
    return () => v.removeEventListener("loadedmetadata", go)
  }, [src, sound])
  useEffect(() => {
    const v = ref.current
    if (!v || sound || reducedMotion() || !autoplayOn() || !globalThis.IntersectionObserver) return
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) v.play().catch(() => {}) // a browser may still refuse; the controls are there
      else v.pause()
    }, { threshold: 0.6 })
    io.observe(v)
    return () => io.disconnect()
  }, [src, sound])
  const video = <video ref={ref} class="media-video" src={src} muted={!sound} loop={!sound} playsinline controls preload="metadata" />
  if (!minimize) return video
  return (
    <span class="video-min-box">
      {video}
      <MinimizeButton video={() => ref.current} url={src} meta={minimize.meta} onDone={minimize.onDone} overlay />
    </span>
  )
}

export const Chevron = ({ left = false }) => (
  <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={left ? "M15 5l-7 7 7 7" : "M9 5l7 7-7 7"} />
  </svg>
)
