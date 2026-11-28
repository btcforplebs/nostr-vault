// What a ~130 px grid tile draws (media perf review 2026-11-28, findings 1-2): a 12 MP original filled the first screen
// of Media with 48 photos, 28.9 MB. A note's imeta can name a small copy (NIP-92 with NIP-94's fields): `thumb`, a
// thumbnail with the same aspect ratio, and `image`, a preview the size of the file (for a video, its poster frame).
// A photo tile draws `thumb` when there is one and the original when there isn't or the thumb fails; a video tile draws
// `thumb`, else `image`, and never the video itself, so no video bytes are read until the note is opened.

import { meshHost } from "../net/fips-ref.js"

// A web link, as imeta urls are (net/note-media.js), but not a .fips one: a plain <img> would send its name (and npub)
// to DNS. Only the original goes through the mesh path (MediaImage), so a failed thumb falls back to it.
const web = u => typeof u === "string" && /^https?:\/\/\S+$/i.test(u) && !meshHost(u) ? u : undefined

/** One imeta tag's "key value" parts -> { key: value }; the first of each key wins (as net/note-media.js). */
function fields(tag) {
  const f = {}
  for (const part of tag.slice(1)) {
    const s = String(part), i = s.indexOf(" ")
    if (i > 0) f[s.slice(0, i)] ??= s.slice(i + 1).trim()
  }
  return f
}

/** The small copies the note's imeta names for `url`: { thumb?, image? }, web links only. */
export function imetaPreview(url, tags) {
  for (const t of tags ?? []) {
    if (t?.[0] !== "imeta") continue
    const f = fields(t)
    if (f.url !== url) continue
    const out = {}, thumb = web(f.thumb), image = web(f.image)
    if (thumb && thumb !== url) out.thumb = thumb
    if (image && image !== url) out.image = image
    return out
  }
  return {}
}

/** A photo tile's small copy: imeta `thumb` (`image` is full size, so it saves nothing for a photo). */
export const photoThumb = (url, tags) => imetaPreview(url, tags).thumb

/** A video tile's still: imeta `thumb`, else `image`; undefined = a plain tile with the play mark. */
export function videoPoster(url, tags) {
  const p = imetaPreview(url, tags)
  return p.thumb ?? p.image
}

/** Vault › Media "In your notes" rows ({ url, noteId, item }, net/vault-lists.js mediaFor) with what each tile draws,
 *  from the note it came from (`own`: your events): a photo's imeta `thumb`, a video's `poster` (the rows include
 *  imeta videos, and an <img> of one read the whole file: 10 MB for 6 clips). Other lists pass through as they are. */
export function withThumbs(mode, filter, items, own) {
  if (mode !== "media" || filter !== "notes" || !items.length) return items
  const tags = new Map(own.map(e => [e.id, e.tags]))
  return items.map(p => {
    const t = tags.get(p.noteId)
    if (p.item?.type === "video") { const poster = videoPoster(p.url, t); return poster ? { ...p, poster } : p }
    const thumb = photoThumb(p.url, t)
    return thumb ? { ...p, thumb } : p
  })
}
