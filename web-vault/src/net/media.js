// The Media feed: the image and video notes among the Following feed's (Haven /feed), one tile each, as the
// iPhone's media grid (FeedView+MediaGrid.swift). A repost shows the note inside it.
const IMAGE = /\.(png|jpe?g|gif|webp|avif)(\?\S*)?$/i
const VIDEO = /\.(mp4|webm|mov|m4v)(\?\S*)?$/i
const URL_RE = /https?:\/\/[^\s<>"]+/gi

/** "image" | "video" | "" for a link, from its extension. */
export function mediaType(url) {
  const path = url.replace(/[#].*$/, "")
  return VIDEO.test(path) ? "video" : IMAGE.test(path) ? "image" : ""
}

/** The note a tile stands for: a kind 1 itself, or the note inside a kind 6 repost. */
export function tileNote(ev) {
  if (ev.kind !== 6) return ev
  try { const inner = JSON.parse(ev.content); return inner?.id && inner.pubkey ? inner : null } catch { return null }
}

/** The image and video links in a note, in order, once each: its text and its NIP-92 imeta tags. */
export function mediaUrls(note) {
  const urls = (String(note.content ?? "").match(URL_RE) ?? []).map(u => u.replace(/[.,;:!?)]+$/, ""))
  for (const t of note.tags ?? []) if (t[0] === "imeta") for (const part of t.slice(1)) if (part.startsWith("url ")) urls.push(part.slice(4).trim())
  return [...new Set(urls)].filter(u => mediaType(u))
}

/** One tile per note with media, newest first as given: { id, note, url, type, count }. A repost of a note already
 *  shown (or two reposts of one note) is one tile. */
export function mediaTiles(events) {
  const seen = new Set(), tiles = []
  for (const ev of events) {
    const note = tileNote(ev)
    if (!note || seen.has(note.id)) continue
    const urls = mediaUrls(note)
    if (!urls.length) continue
    seen.add(note.id)
    tiles.push({ id: note.id, note, url: urls[0], type: mediaType(urls[0]), count: urls.length })
  }
  return tiles
}
