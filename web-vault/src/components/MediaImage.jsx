// One note image (NoteMedia, MediaLightbox). An https photo is a plain <img>. A photo on a FIPS vault loads by
// itself once it nears the screen (fips-media.js): a NIP-F1 .fips link at once, an https photo after its server
// fails when the imeta gives its hash and the author lists a fipsmesh:// vault. A spinner while it loads, a plain
// box if it can't be reached.
import { useEffect, useRef, useState } from "preact/hooks"
import { fipsRef } from "../net/fips-ref.js"
import { fipsMedia } from "../net/fips-media.js"
import { Spinner } from "./Loading.jsx"

const NEAR = "600px" // start the read this far before the photo scrolls into view

/** `item`: { url, x?, width?, height? } (noteMedia); `author`: the note's pubkey, for its 10063. `load`: tests. */
export function MediaImage({ item, author, load = (it, who) => fipsMedia().fallback(it, who), ...img }) {
  const mesh = !!fipsRef(item.url)
  // "web": the url itself; "wait": a mesh read is due; "mesh": src is a blob: URL; "failed": nothing reached it
  const [state, setState] = useState(mesh ? "wait" : "web")
  const [src, setSrc] = useState(mesh ? undefined : item.url)
  const [why, setWhy] = useState("")
  const box = useRef()

  useEffect(() => { setState(mesh ? "wait" : "web"); setSrc(mesh ? undefined : item.url) }, [item.url])
  useEffect(() => {
    if (state !== "wait") return
    let live = true
    const start = () => load(item, author).then(u => { if (live) { setSrc(u); setState("mesh") } }, e => { if (live) { setWhy(String(e?.message ?? e)); setState("failed") } })
    const el = box.current
    if (!el || typeof IntersectionObserver !== "function") { start(); return () => { live = false } }
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); start() } }, { rootMargin: NEAR })
    io.observe(el)
    return () => { live = false; io.disconnect() }
  }, [state, item.url])

  // A web photo whose server fails gets one mesh try when there is a hash to ask for.
  const onError = () => { if (state === "web" && item.x && author) setState("wait") }

  if (state === "wait") return <span ref={box} class="media-mesh" style={ratio(item)}><Spinner label="Loading photo" /></span>
  if (state === "failed") return <span class="media-mesh failed" style={ratio(item)} title={why}>Photo not reachable</span>
  return <img src={src} alt="" referrerpolicy="no-referrer" onError={onError} {...img} />
}

// Hold the photo's own shape while it loads, when the note says it.
const ratio = it => (it.width && it.height ? { aspectRatio: `${it.width} / ${it.height}` } : undefined)
