// A note's images and videos under its text, as iOS FeedNoteRow+Media.swift: one item full width, at most 400 tall;
// several a swipeable carousel 400 tall with a page indicator, every page filling it. A tap on an image opens them
// all full screen (MediaLightbox, iOS FeedMediaViewer). Cards don't open their thread on a tap in `.media-box`.
import { useRef, useState } from "preact/hooks"
import { MediaLightbox } from "./MediaLightbox.jsx"
import { Chevron, InlineVideo } from "./MediaParts.jsx"
import { MediaImage } from "./MediaImage.jsx"
import { pageOf, scrollToPage } from "./pager.js"

// Vite only: the node tests load this file without a CSS loader, and there import.meta.env is undefined.
if (import.meta.env) import("../styles/media.css")

const MAX_DOTS = 10 // past this the "2/14" counter says it; a row of dots wouldn't fit

/** `items`: [{ url, type: "image" | "video", width?, height?, x? }] (noteMedia); `author`: the note's pubkey, whose
 *  10063 may name a mesh vault for a photo its server can't serve (MediaImage). */
export function NoteMedia({ items, author }) {
  const [open, setOpen] = useState(-1)
  return (
    <div class="media-box">
      {items.length === 1
        ? <div class="media-one"><MediaItem item={items[0]} author={author} onOpen={() => setOpen(0)} /></div>
        : <MediaCarousel items={items} author={author} onOpen={setOpen} />}
      {open >= 0 && <MediaLightbox items={items} author={author} start={open} onClose={() => setOpen(-1)} />}
    </div>
  )
}

function MediaItem({ item, author, onOpen }) {
  if (item.type === "video") return <InlineVideo src={item.url} />
  return (
    <button type="button" class="media-tap" aria-label="View image" onClick={onOpen}>
      <MediaImage item={item} author={author} loading="lazy" decoding="async" width={item.width} height={item.height} />
    </button>
  )
}

function MediaCarousel({ items, author, onOpen }) {
  const track = useRef(), [at, setAt] = useState(0), n = items.length
  const go = i => scrollToPage(track.current, i, n)
  return (
    <div class="media-carousel" role="group" aria-roledescription="carousel" aria-label={`${n} photos and videos`}>
      <div class="media-track" ref={track} onScroll={() => setAt(pageOf(track.current))}>
        {items.map((it, i) => (
          <div key={it.url} class="media-slide" role="group" aria-roledescription="slide" aria-label={`${i + 1} of ${n}`}>
            <MediaItem item={it} author={author} onOpen={() => onOpen(i)} />
          </div>
        ))}
      </div>
      {at > 0 && <button type="button" class="media-nav prev" aria-label="Previous" onClick={() => go(at - 1)}><Chevron left /></button>}
      {at < n - 1 && <button type="button" class="media-nav next" aria-label="Next" onClick={() => go(at + 1)}><Chevron /></button>}
      <span class="media-count" aria-live="polite">{at + 1}/{n}</span>
      {n <= MAX_DOTS && <div class="media-dots" aria-hidden="true">{items.map((_, i) => <span key={i} class={i === at ? "on" : undefined} />)}</div>}
    </div>
  )
}
