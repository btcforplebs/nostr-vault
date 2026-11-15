// A DM photo or video sent as an encrypted kind 15 (net/dm-file.js): the ciphertext is fetched, checked against its hash
// and decrypted here, then drawn from memory. A stranger's photo waits for a tap, as their plain photo links do
// (TapImage); a video also waits when it is big, showing its size, then how much has arrived.
import { useEffect, useRef, useState } from "preact/hooks"
import { AUTO_SHOW_MAX, MAX_FILE, openFileLink, parseFileLink } from "../net/dm-file.js"

/** The biggest video a thread opens by itself (the phones' DMFileLoader.AUTO_SHOW_MAX); a bigger one waits for a tap.
 *  The size tag only decides whether to try: the read itself is held to it (openFileLink max). */
export const AUTO_VIDEO_MAX = AUTO_SHOW_MAX

/** "12.4 MB" for a byte count. */
export const sizeText = n => n >= 1024 * 1024 ? `${(n / (1024 * 1024)).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`

export function DmPhoto({ link, load }) {
  const f = parseFileLink(link)
  if (/^video\//i.test(f?.mime ?? "")) return <DmVideo link={link} load={load && !!f.size && f.size <= AUTO_VIDEO_MAX} size={f.size} />
  return <DmImage link={link} load={load} />
}

function DmImage({ link, load }) {
  const [on, setOn] = useState(load)
  const [tapped, setTapped] = useState(false) // only a tap opens past AUTO_SHOW_MAX
  const [bigger, setBigger] = useState(false)
  const [src, setSrc] = useState("")
  const [failed, setFailed] = useState(false)
  useEffect(() => { if (load) setOn(true) }, [load])
  useEffect(() => {
    if (!on) return
    let url = "", gone = false
    const stop = new AbortController()
    setBigger(false)
    openFileLink(link, { max: tapped ? MAX_FILE : AUTO_SHOW_MAX, signal: stop.signal }).then(blob => {
      if (gone) return
      if (!/^image\//.test(blob.type)) { setFailed(true); return }
      url = URL.createObjectURL(blob); setSrc(url)
    }, e => { if (!gone) { if (e?.tooBig) { setBigger(true); setOn(false) } else setFailed(true) } })
    return () => { gone = true; stop.abort(); if (url) URL.revokeObjectURL(url) }
  }, [on, link, tapped])
  if (!on) {
    let host = ""
    try { host = new URL(parseFileLink(link)?.url ?? "").host } catch {}
    return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setTapped(true); setOn(true) }}>{bigger ? "Bigger than it said. " : ""}Show photo{host ? ` from ${host}` : ""}</button>
  }
  if (failed) return <span class="dm-photo-failed">This photo couldn't load.</span>
  return src ? <img class="note-media" src={src} alt="Photo" /> : <span class="dm-photo-loading">Photo…</span>
}

/** A locked video: plays silently in the bubble once opened; a tap opens it full screen with sound and controls. */
function DmVideo({ link, load, size }) {
  const [on, setOn] = useState(load)
  const [src, setSrc] = useState("")
  const [failed, setFailed] = useState(false)
  const [got, setGot] = useState(0)
  const [tries, setTries] = useState(0) // each Try again opens it afresh
  const [tapped, setTapped] = useState(false) // only a tap opens past AUTO_SHOW_MAX: the size tag is the sender's word
  const [bigger, setBigger] = useState(false)
  const [total, setTotal] = useState(size ?? -1)
  const video = useRef(null)
  useEffect(() => { if (load) setOn(true) }, [load])
  useEffect(() => {
    if (!on) return
    let url = "", gone = false
    // Leaving the thread (or a new try) stops the download, not only the drawing.
    const stop = new AbortController()
    setFailed(false); setBigger(false); setGot(0)
    openFileLink(link, { max: tapped ? MAX_FILE : AUTO_SHOW_MAX, signal: stop.signal, onProgress: (n, all) => { if (gone) return; setGot(n); if (all > 0) setTotal(all) } }).then(blob => {
      if (gone) return
      if (!/^video\//.test(blob.type)) { setFailed(true); return }
      url = URL.createObjectURL(blob); setSrc(url)
    }, e => { if (!gone) { if (e?.tooBig) { setBigger(true); setOn(false) } else setFailed(true) } })
    return () => { gone = true; stop.abort(); if (url) URL.revokeObjectURL(url) }
  }, [on, link, tries, tapped])
  if (!on || failed) {
    return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setTapped(true); setOn(true); if (failed) setTries(n => n + 1) }}>
      {failed ? "This video couldn't load. Try again" : `${bigger ? "Bigger than it said. " : ""}Show video${size ? ` · ${sizeText(size)}` : ""}`}
    </button>
  }
  if (!src) {
    return <span class="dm-photo-loading" role="status">
      Video… {total > 0 ? `${sizeText(got)} of ${sizeText(total)}` : sizeText(got)}
      {total > 0 && <progress max={total} value={got} />}
    </span>
  }
  const full = e => {
    e.stopPropagation()
    const v = video.current
    if (!v) return
    v.controls = true; v.muted = false
    if (v.requestFullscreen) v.requestFullscreen().catch(() => {})
    else v.webkitEnterFullscreen?.() // iPhone Safari: only a video element goes full screen
    v.play?.().catch(() => {})
  }
  return <video ref={video} class="note-media dm-video" src={src} muted autoplay loop playsinline aria-label="Video" onClick={full}
    onFullscreenChange={() => { const v = video.current; if (v && !document.fullscreenElement) { v.controls = false; v.muted = true } }} />
}
