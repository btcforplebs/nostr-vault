// A horizontal scroll-snap pager (NoteMedia's carousel, MediaLightbox): one page per container width.

/** The page showing in `track`, 0-based. */
export const pageOf = track => track && track.clientWidth ? Math.round(track.scrollLeft / track.clientWidth) : 0

/** Scrolls `track` to page `i` (clamped), smoothly unless the user asks for reduced motion. */
export function scrollToPage(track, i, count) {
  if (!track) return
  const page = Math.max(0, Math.min(count - 1, i))
  track.scrollTo({ left: page * track.clientWidth, behavior: reducedMotion() ? "auto" : "smooth" })
}

export const reducedMotion = () => globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false
