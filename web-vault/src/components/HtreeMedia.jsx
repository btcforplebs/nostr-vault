// An htree:// (Iris hashtree) photo in a note, drawn like any picture once its blob is fetched, checked, decrypted and
// checked again (net/htree.js). It shares BlossomMedia's cache, keyed by the photo's plain sha256: until it loads a
// quiet "Loading photo…", and "Photo unavailable" when no server has it, never the raw link. With images off (a
// stranger's DM, or pictures that wait) nothing is fetched until it is tapped.
import { useEffect, useState } from "preact/hooks"
import { releaseBlossom, retainBlossom } from "../net/blossom-uri.js"
import { authorList, fetchHtree, htreeServers, ownList } from "../net/htree.js"
import { quoteSource } from "../net/quotes.js"

export function HtreeMedia({ h, author, images = true }) {
  const [asked, setAsked] = useState(images)
  const [got, setGot] = useState(undefined) // undefined: loading; null: unavailable
  useEffect(() => {
    if (!asked) return
    let live = true
    setGot(undefined)
    const src = quoteSource()
    const fetchFile = async () => {
      const [theirs, mine] = await Promise.all([authorList(author, src?.relays ?? []), ownList(src?.vault)])
      return fetchHtree(h, htreeServers(theirs, mine))
    }
    retainBlossom(h, { fetchFile }).then(r => live && setGot(r)).catch(() => live && setGot(null))
    return () => { live = false; releaseBlossom(h.sha256) }
  }, [h.sha256, asked])
  if (!asked) return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setAsked(true) }}>Show photo</button>
  if (got === undefined) return <span class="blossom-media pending muted small" role="status">Loading photo…</span>
  if (!got) return <span class="blossom-media missing muted small">Photo unavailable</span>
  return <img class="note-media" src={got.url} alt={h.name || ""} loading="lazy" />
}
