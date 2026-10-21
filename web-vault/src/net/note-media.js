// A note's images and videos, as iOS takes them (NostrEvent.mediaURLs): the media links in its text, in order, then
// its NIP-92 imeta urls not already there, each once. NoteText draws them under the text (NoteMedia) and leaves the
// links out of it, as NostrContentFormatter strips mediaURLs.
import { mediaType } from "./media.js"
import { fipsRef } from "./fips-ref.js"

// Nostr web clients serve a page, not a file, at /<64-hex> (SupportedMediaFormats.webPageHosts).
const WEB_PAGE_HOSTS = new Set([
  "njump.me", "njump.to", "primal.net", "nostr.band", "snort.social", "iris.to", "coracle.social", "nostrudel.ninja",
  "habla.news", "yakihonne.com", "nostter.app", "jumble.social", "nostr.com", "damus.io", "zap.stream", "highlighter.com",
  "nostr.at", "nostr.eu", "nostrrr.com", "flycat.club", "nostrapp.link", "nostr.watch",
])

export function isWebPageHost(url) {
  try { return WEB_PAGE_HOSTS.has(new URL(url).host.toLowerCase().replace(/^www\./, "")) } catch { return false }
}

// The last path part has an extension (".mp3", ".html"): then that decides, not the imeta mime.
const hasExtension = url => { try { return /\.[a-z0-9]{2,5}$/i.test(new URL(url).pathname) } catch { return false } }

/** One imeta tag's fields: ["imeta", "url https://…", "m image/png", "dim 640x480"] -> { url, m, dim }. First wins. */
function imetaFields(tag) {
  const f = {}
  for (const part of tag.slice(1)) {
    const i = String(part).indexOf(" ")
    if (i > 0) f[part.slice(0, i)] ??= part.slice(i + 1).trim()
  }
  return f
}

/** "image" | "video" | "" for an imeta url (SupportedMediaFormats.isImetaMediaURL): its extension when it has one,
 *  else its `m` mime; an extensionless upload with no mime is an image unless the host is a web page. */
export function imetaType(url, mime = "") {
  const byExt = mediaType(url)
  if (byExt || hasExtension(url)) return byExt
  if (/^video\//i.test(mime)) return "video"
  if (/^image\//i.test(mime)) return "image"
  if (mime) return ""
  return isWebPageHost(url) ? "" : "image"
}

/** The imeta media of a note, by url: { url, type, width?, height?, x? } (x: its sha256, for a mesh fallback). */
export function imetaMedia(tags) {
  const out = new Map()
  for (const t of tags ?? []) {
    if (t?.[0] !== "imeta") continue
    const f = imetaFields(t)
    if (!/^https?:\/\//i.test(f.url ?? "") || out.has(f.url)) continue
    const type = imetaType(f.url, f.m)
    if (!type) continue
    const [, w, h] = /^(\d+)x(\d+)$/.exec(f.dim ?? "") ?? []
    const m = w && h ? { url: f.url, type, width: +w, height: +h } : { url: f.url, type }
    if (/^[0-9a-f]{64}$/i.test(f.x ?? "")) m.x = f.x.toLowerCase()
    out.set(f.url, m)
  }
  return out
}

/** The links in a note's text (already trimmed of trailing punctuation) and its tags -> its media, in order, each
 *  once: text media first, then imeta-only media. A text link imeta describes (an extensionless Blossom url) is media
 *  too, and keeps its place in the text order. */
export function noteMedia(links, tags) {
  const meta = imetaMedia(tags), seen = new Set(), out = []
  const add = m => { if (!seen.has(m.url)) { seen.add(m.url); out.push(m) } }
  for (const url of links) {
    // A NIP-F1 link (http://<npub>.fips/<sha256>) is a photo on a mesh vault, extension or not.
    const m = meta.get(url), type = m?.type || mediaType(url) || (fipsRef(url) ? "image" : "")
    if (type) add(m ?? { url, type })
  }
  for (const m of meta.values()) add(m)
  return out
}
