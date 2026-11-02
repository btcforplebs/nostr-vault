// The compact row's photo on a wide window (Logen, 2026-11-02 polish): a click opens the note's photos and videos full
// size (MediaLightbox), as a photo in a full note does, instead of the thread. On a phone (thumbOpens false) the row's tap
// opens the thread, as on the iPhone (components/CondensedNote.jsx Thumb).
import { useState } from "preact/hooks"
import { MediaImage } from "../components/MediaImage.jsx"
import { MediaLightbox } from "../components/MediaLightbox.jsx"
import { mediaType } from "../net/media.js"
import { imageItem } from "../net/note-media.js"
import { deskModeFor } from "./routes.js"

/** The note's media as the lightbox takes it. */
export const lightboxItems = (media, tags) => media.map(u => (mediaType(u) === "video" ? { url: u, type: "video" } : imageItem(u, tags)))

/** Whether the compact row's photo opens full size here: on the desktop layout's widths. */
export const thumbOpens = () => typeof innerWidth === "number" && deskModeFor(innerWidth) !== "phone"

/** The clickable photo, with the +N badge, and the lightbox once clicked. */
export function ThumbOpen({ media, note, more, big }) {
  const [open, setOpen] = useState(false)
  const url = media[0]
  return (
    <span class={`condensed-thumb${big ? " big" : ""}`}>
      <button type="button" class="condensed-pic condensed-open" aria-label={more > 0 ? `View ${more + 1} photos and videos` : "View image"}
        onClick={e => { e.stopPropagation(); setOpen(true) }}>
        <MediaImage item={imageItem(url, note.tags)} author={note.pubkey} loading="lazy" onError={e => e.currentTarget.classList.add("failed")} />
        {more > 0 && <span class="condensed-more">+{more}</span>}
      </button>
      {open && <MediaLightbox items={lightboxItems(media, note.tags)} author={note.pubkey} onClose={() => setOpen(false)} />}
    </span>
  )
}
