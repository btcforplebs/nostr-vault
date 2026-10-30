// A BUD-10 blossom: link in a note, drawn like an https picture or video once its bytes are fetched and checked against
// the sha256 it names (net/blossom-uri.js). Until then a quiet "Loading media…"; when no server has it, "Media
// unavailable", never the raw link. In a stranger's DM (`images` false) nothing is fetched until it is tapped, as an
// https picture there waits (NoteText TapImage).
import { useEffect, useState } from "preact/hooks"
import { loadBlossom } from "../net/blossom-uri.js"
import { quoteSource } from "../net/quotes.js"

export function BlossomMedia({ b, author, images = true, dm = false }) {
  const [asked, setAsked] = useState(images)
  const [got, setGot] = useState(undefined) // undefined: loading; null: unavailable
  useEffect(() => {
    if (!asked) return
    let live = true
    setGot(undefined)
    loadBlossom(b, { author, relays: quoteSource()?.relays ?? [] }).then(r => live && setGot(r)).catch(() => live && setGot(null))
    return () => { live = false }
  }, [b.sha256, asked])
  if (!asked) return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setAsked(true) }}>Show media</button>
  if (got === undefined) return <span class="blossom-media pending muted small" role="status">Loading media…</span>
  if (!got) return <span class="blossom-media missing muted small">Media unavailable</span>
  if (got.kind === "video") return dm ? <a href={got.url} target="_blank" rel="noopener">Video</a> : <video class="note-media" src={got.url} controls preload="metadata" playsinline />
  return <img class="note-media" src={got.url} alt="" loading="lazy" />
}
