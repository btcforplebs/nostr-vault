// The Media feed's grid (net/media.js): square tiles, three across on a phone and more on a wide window, each the
// first image or video of a note, with a mark for a video or for several. A tap opens the note's thread, as on the
// iPhone (FeedView+MediaGrid.swift). A photo draws its imeta `thumb` when the note names one, else the original; a
// video draws its poster (imeta `thumb` or `image`) or a plain tile, never the video, so no video bytes load until the
// note is opened (grid-thumb.js). A photo whose server lost it, or a .fips one, comes from the author's mesh vault
// (MediaImage), as in the note itself.
import { useState } from "preact/hooks"
import { MediaImage } from "./MediaImage.jsx"
import { imageItem } from "../net/note-media.js"
import { photoThumb, videoPoster } from "./grid-thumb.js"

export function MediaGrid({ tiles }) {
  return (
    <div class="media-grid">
      {tiles.map(t => (
        <a key={t.id} class="media-tile" href={`#/thread/${t.id}`} aria-label={`${t.type === "video" ? "Video" : "Image"} note${t.count > 1 ? `, ${t.count} items` : ""}`}>
          {t.type === "video"
            ? <VideoPoster src={videoPoster(t.url, t.note?.tags)} />
            : <GridPhoto item={imageItem(t.url, t.note?.tags)} thumb={photoThumb(t.url, t.note?.tags)} author={t.note?.pubkey} />}
          {(t.count > 1 || t.type === "video") && <span class="media-mark" aria-hidden="true">{t.count > 1 ? <StackIcon /> : <PlayIcon />}</span>}
        </a>
      ))}
    </div>
  )
}

/** A photo tile: the small copy first; if it fails, the original, which keeps MediaImage's mesh fallback. */
export function GridPhoto({ item, thumb, author }) {
  const [small, setSmall] = useState(true)
  if (thumb && small) return <img key={thumb} src={thumb} alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer" onError={() => setSmall(false)} />
  return <MediaImage item={item} author={author} loading="lazy" decoding="async" />
}

/** A video tile's still, or nothing (the tile's own background and the play mark) when there is none or it fails. */
function VideoPoster({ src }) {
  const [ok, setOk] = useState(true)
  return src && ok ? <img src={src} alt="" loading="lazy" decoding="async" referrerpolicy="no-referrer" onError={() => setOk(false)} /> : null
}

const PlayIcon = () => <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M7 4.5v15l13-7.5z" /></svg>
const StackIcon = () => (
  <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M8 3h13v13H8z" /><path d="M3 8h3v10a2 2 0 0 0 2 2h10v1H3z" /></svg>
)
