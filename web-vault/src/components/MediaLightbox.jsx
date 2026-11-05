// A note's media full screen, as iOS FeedMediaViewer: a pager over all of it, opened at the tapped item. Swipe or
// the arrows (← → keys) to page; Esc, ✕ or a click outside the picture closes it. Drawn into <body>, so its clicks
// never reach the card behind it. Swipe up (or ↑, or the Notes button) shows the notes on your vault that use the
// item on screen (MediaNotesSheet.jsx), as the Vault gallery does; only when this page has a vault (not a guest).
import { createPortal } from "preact/compat"
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks"
import { Chevron, InlineVideo } from "./MediaParts.jsx"
import { MediaImage } from "./MediaImage.jsx"
import { pageOf, scrollToPage } from "./pager.js"
import { MediaNotesSheet } from "./MediaNotesSheet.jsx"
import { quoteSource } from "../net/quotes.js"
import { swipedUp } from "./swipe-up.js"

export function MediaLightbox({ items, author, start = 0, onClose }) {
  const track = useRef(), closeRef = useRef(), [at, setAt] = useState(start), n = items.length
  const vault = quoteSource()?.vault
  const [notes, setNotes] = useState(false) // the notes sheet for the item on screen
  const notesRef = useRef(false); notesRef.current = notes
  const touch = useRef(null)
  const go = i => scrollToPage(track.current, i, n)

  useLayoutEffect(() => { const t = track.current; if (t) t.scrollLeft = start * t.clientWidth }, [])
  useEffect(() => {
    const key = e => {
      if (e.key === "Escape") { e.preventDefault(); if (notesRef.current) setNotes(false); else onClose() }
      else if (e.key === "ArrowUp" && vault) { e.preventDefault(); setNotes(true) }
      else if (e.key === "ArrowDown") setNotes(false)
      else if (e.key === "ArrowLeft") go(pageOf(track.current) - 1)
      else if (e.key === "ArrowRight") go(pageOf(track.current) + 1)
    }
    const back = document.activeElement, overflow = document.body.style.overflow
    document.addEventListener("keydown", key)
    document.body.style.overflow = "hidden" // the feed behind doesn't scroll under it
    closeRef.current?.focus()
    return () => { document.removeEventListener("keydown", key); document.body.style.overflow = overflow; back?.focus?.({ preventScroll: true }) }
  }, [])

  const outside = e => { if (!e.target.closest("img, video, button, .lightbox-notes")) onClose() }
  const down = e => { const t = e.touches?.[0]; touch.current = t && e.touches.length === 1 ? { x: t.clientX, y: t.clientY } : null }
  const up = e => { const t = e.changedTouches?.[0]; if (vault && touch.current && t && swipedUp(touch.current, { x: t.clientX, y: t.clientY })) setNotes(true); touch.current = null }
  return createPortal(
    <div class="lightbox" role="dialog" aria-modal="true" aria-label="Photos and videos" onClick={outside} onTouchStart={down} onTouchEnd={up}>
      <div class="lightbox-track" ref={track} onScroll={() => setAt(pageOf(track.current))}>
        {items.map((it, i) => (
          <div key={it.url} class="lightbox-page" aria-label={`${i + 1} of ${n}`}>
            {it.type === "video" ? <InlineVideo src={it.url} />
              : <MediaImage item={it} author={author} decoding="async" loading={Math.abs(i - start) > 1 ? "lazy" : undefined} />}
          </div>
        ))}
      </div>
      <button type="button" ref={closeRef} class="lightbox-close" aria-label="Close" onClick={onClose}>
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
      </button>
      {n > 1 && <span class="lightbox-count">{at + 1} / {n}</span>}
      {at > 0 && <button type="button" class="media-nav prev" aria-label="Previous" onClick={() => go(at - 1)}><Chevron left /></button>}
      {at < n - 1 && <button type="button" class="media-nav next" aria-label="Next" onClick={() => go(at + 1)}><Chevron /></button>}
      {vault && !notes && <button type="button" class="lightbox-notes-btn" onClick={() => setNotes(true)} title="Swipe up, or ↑">Notes that use this</button>}
      {vault && notes && items[at] && <MediaNotesSheet vault={vault} item={items[at]} onOpen={onClose} onClose={() => setNotes(false)} />}
    </div>,
    document.body,
  )
}
