// A DM photo or video sent as an encrypted kind 15 (net/dm-file.js): the ciphertext is fetched, checked against its hash
// and decrypted here, then drawn from memory. A stranger's photo waits for a tap, as their plain photo links do
// (TapImage); a video also waits when it is big, showing its size, then how much has arrived.
import { useEffect, useRef, useState } from "preact/hooks"
import { openFileLink, parseFileLink } from "../net/dm-file.js"

/** The biggest video a thread opens by itself (the phones' DMFileLoader.AUTO_SHOW_MAX); a bigger one waits for a tap. */
export const AUTO_VIDEO_MAX = 16 * 1024 * 1024

/** "12.4 MB" for a byte count. */
export const sizeText = n => n >= 1024 * 1024 ? `${(n / (1024 * 1024)).toFixed(1)} MB` : `${Math.ceil(n / 1024)} KB`

export function DmPhoto({ link, load }) {
  const f = parseFileLink(link)
  if (/^video\//i.test(f?.mime ?? "")) return <DmVideo link={link} load={load && !!f.size && f.size <= AUTO_VIDEO_MAX} size={f.size} />
  return <DmImage link={link} load={load} />
}

function DmImage({ link, load }) {
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

/** A locked video: plays silently in the bubble once opened; a tap opens it full screen with sound and controls. */
function DmVideo({ link, load, size }) {
  const [on, setOn] = useState(load)
  const [src, setSrc] = useState("")
  const [failed, setFailed] = useState(false)
  const [got, setGot] = useState(0)
  const [tries, setTries] = useState(0) // each Try again opens it afresh
  const [total, setTotal] = useState(size ?? -1)
  const video = useRef(null)
  useEffect(() => { if (load) setOn(true) }, [load])
  useEffect(() => {
    if (!on) return
    let url = "", gone = false
    setFailed(false); setGot(0)
    openFileLink(link, { onProgress: (n, all) => { if (gone) return; setGot(n); if (all > 0) setTotal(all) } }).then(blob => {
      if (gone) return
      if (!/^video\//.test(blob.type)) { setFailed(true); return }
      url = URL.createObjectURL(blob); setSrc(url)
    }, () => { if (!gone) setFailed(true) })
    return () => { gone = true; if (url) URL.revokeObjectURL(url) }
  }, [on, link, tries])
  if (!on || failed) {
    return <button type="button" class="small tap-image" onClick={e => { e.stopPropagation(); setOn(true); if (failed) setTries(n => n + 1) }}>
      {failed ? "This video couldn't load. Try again" : `Show video${size ? ` · ${sizeText(size)}` : ""}`}
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
