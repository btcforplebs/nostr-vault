// One note image (NoteMedia, MediaLightbox). An https photo is a plain <img>. A photo on a FIPS vault loads by
// itself once it nears the screen (fips-media.js), only in notes from you or people you follow and only with the
// Settings switch on: a NIP-F1 .fips link at once, an https photo after its server fails when the imeta gives its
// hash and the author lists a fipsmesh:// vault. A spinner while it loads, a plain box if it can't be reached.
// Leaving the page stops its read and lets its blob: URL go. When the gate changes (a follow added, the switch
// flipped) a photo still waiting re-checks it: one now allowed starts, one no longer allowed stops.
import { useEffect, useRef, useState } from "preact/hooks"
import { fipsRef } from "../net/fips-ref.js"
import { fipsMedia, meshAllowed, onMeshGate } from "../net/fips-media.js"
import { Spinner } from "./Loading.jsx"

const NEAR = "600px" // start the read this far before the photo scrolls into view

/** `item`: { url, x?, width?, height? } (noteMedia); `author`: the note's pubkey, for its 10063. `media`, `allowed`,
 *  `gate`: tests. */
export function MediaImage({ item, author, media = fipsMedia(), allowed = meshAllowed, gate = onMeshGate, ...img }) {
  const first = () => (fipsRef(item.url) ? (allowed(author) ? "wait" : "failed") : "web")
  // "web": the url itself; "wait": a mesh read is due; "mesh": src is a blob: URL; "failed": nothing reached it
  const [state, setState] = useState(first)
  const [src, setSrc] = useState(state === "web" ? item.url : undefined)
  const [why, setWhy] = useState("")
  const box = useRef(), ctl = useRef()
  const gated = useRef(false) // a mesh read is due but the author may not use the mesh (yet)
  const [ver, setVer] = useState(0)
  useEffect(() => gate(() => setVer(v => v + 1)), [gate])

  useEffect(() => {
    const s = first()
    gated.current = s === "failed"
    setState(s); setSrc(s === "web" ? item.url : undefined)
    return () => ctl.current?.abort() // a new url or gone from the page: the read stops, the URL can be released
  }, [item.url])

  // The gate changed: a photo held back only by it starts now; one waiting or reading that may no longer stops.
  useEffect(() => {
    if (!ver) return
    const ok = allowed(author)
    if (ok && gated.current) { gated.current = false; setState("wait") }
    else if (!ok && state === "wait") { gated.current = true; setWhy("mesh photos are off for this note"); setState("failed") }
  }, [ver])

  useEffect(() => {
    if (state !== "wait") return
    let live = true, got = false
    const start = () => {
      ctl.current?.abort()
      const c = (ctl.current = new AbortController())
      media.fallback(item, author, { signal: c.signal }).then(
        u => { got = true; if (live) { setSrc(u); setState("mesh") } },
        e => { if (live && e?.name !== "AbortError") { setWhy(String(e?.message ?? e)); setState("failed") } })
    }
    const el = box.current
    const io = el && typeof IntersectionObserver === "function"
      && new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); start() } }, { rootMargin: NEAR })
    if (io) io.observe(el)
    else start()
    return () => { live = false; if (io) io.disconnect(); if (!got) ctl.current?.abort() }
  }, [state, item.url])

  // A web photo whose server fails gets one mesh try when there is a hash to ask for and the author may use the mesh.
  const onError = () => {
    if (state !== "web" || !item.x) return
    if (allowed(author)) setState("wait")
    else gated.current = true // the image stays broken; a later follow or the switch can still start a mesh try
  }

  if (state === "wait") return <span ref={box} class="media-mesh" style={ratio(item)}><Spinner label="Loading photo" /></span>
  if (state === "failed") return <span class="media-mesh failed" style={ratio(item)} title={why}>Photo not reachable</span>
  return <img src={src} alt="" referrerpolicy="no-referrer" onError={onError} {...img} />
}

// Hold the photo's own shape while it loads, when the note says it.
const ratio = it => (it.width && it.height ? { aspectRatio: `${it.width} / ${it.height}` } : undefined)
