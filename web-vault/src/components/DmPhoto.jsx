// A DM photo sent as an encrypted kind 15 (net/dm-file.js): the ciphertext is fetched, checked against its hash and
// decrypted here, then drawn from memory. A stranger's photo waits for a tap, as their plain photo links do (TapImage).
import { useEffect, useState } from "preact/hooks"
import { openFileLink, parseFileLink } from "../net/dm-file.js"

export function DmPhoto({ link, load }) {
  const [on, setOn] = useState(load)
  const [src, setSrc] = useState("")
  const [failed, setFailed] = useState(false)
  useEffect(() => { if (load) setOn(true) }, [load])
  useEffect(() => {
    if (!on) return
    let url = "", gone = false
    openFileLink(link).then(blob => {
      if (gone) return
      if (!/^image\//.test(blob.type)) { setFailed(true); return }
      url = URL.createObjectURL(blob); setSrc(url)
    }, () => { if (!gone) setFailed(true) })
    return () => { gone = true; if (url) URL.revokeObjectURL(url) }
  }, [on, link])
  if (!on) {
    let host = ""
    try { host = new URL(parseFileLink(link)?.url ?? "").host } catch {}
    return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setOn(true) }}>Show photo{host ? ` from ${host}` : ""}</button>
  }
  if (failed) return <span class="dm-photo-failed">This photo couldn't load.</span>
  return src ? <img class="note-media" src={src} alt="Photo" /> : <span class="dm-photo-loading">Photo…</span>
}
