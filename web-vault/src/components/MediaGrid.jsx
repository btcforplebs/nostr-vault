// The Media feed's grid (net/media.js): square tiles, three across on a phone and more on a wide window, each the
// first image or video of a note, with a mark for a video or for several. A tap opens the note's thread, as on the
// iPhone (FeedView+MediaGrid.swift). Videos load only enough to show a frame. A photo whose server lost it, or a .fips
// one, comes from the author's mesh vault (MediaImage), as in the note itself.
import { MediaImage } from "./MediaImage.jsx"
import { imageItem } from "../net/note-media.js"

export function MediaGrid({ tiles }) {
  return (
    <div class="media-grid">
      {tiles.map(t => (
        <a key={t.id} class="media-tile" href={`#/thread/${t.id}`} aria-label={`${t.type === "video" ? "Video" : "Image"} note${t.count > 1 ? `, ${t.count} items` : ""}`}>
          {t.type === "video"
            ? <video src={`${t.url}#t=0.1`} preload="metadata" muted playsinline tabIndex={-1} />
            : <MediaImage item={imageItem(t.url, t.note?.tags)} author={t.note?.pubkey} loading="lazy" decoding="async" />}
          {(t.count > 1 || t.type === "video") && <span class="media-mark" aria-hidden="true">{t.count > 1 ? <StackIcon /> : <PlayIcon />}</span>}
        </a>
      ))}
    </div>
  )
}

const PlayIcon = () => <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M7 4.5v15l13-7.5z" /></svg>
const StackIcon = () => (
  <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M8 3h13v13H8z" /><path d="M3 8h3v10a2 2 0 0 0 2 2h10v1H3z" /></svg>
)
