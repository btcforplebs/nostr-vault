// Pieces NoteMedia and MediaLightbox share.
import { useEffect, useRef } from "preact/hooks"
import { reducedMotion } from "./pager.js"

/** A video in a note, as iOS InlineFeedVideoPlayer (FeedMediaView.swift): muted, looping, playing inline while it is
 *  on screen, with controls. No autoplay when the user asks for reduced motion. */
export function InlineVideo({ src }) {
  const ref = useRef()
  useEffect(() => {
    const v = ref.current
    if (!v || reducedMotion() || !globalThis.IntersectionObserver) return
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) v.play().catch(() => {}) // a browser may still refuse; the controls are there
      else v.pause()
    }, { threshold: 0.6 })
    io.observe(v)
    return () => io.disconnect()
  }, [src])
  return <video ref={ref} class="media-video" src={src} muted loop playsinline controls preload="metadata" />
}

export const Chevron = ({ left = false }) => (
  <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d={left ? "M15 5l-7 7 7 7" : "M9 5l7 7-7 7"} />
  </svg>
)
