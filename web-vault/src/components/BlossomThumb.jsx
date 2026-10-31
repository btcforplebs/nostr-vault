// A Vault › Media grid tile's picture: the kept small copy (net/blossom-thumbs.js) once the tile nears the screen,
// or the original when no small copy can be made.
import { useEffect, useRef, useState } from "preact/hooks"
import { thumbStore } from "../net/blossom-thumbs.js"

let shared = null

export function BlossomThumb({ blob }) {
  const ref = useRef(null)
  const [src, setSrc] = useState("")
  useEffect(() => {
    let alive = true, url = ""
    const load = () => (shared ||= thumbStore()).get(blob).then(small => {
      if (!alive) return
      if (small) { url = URL.createObjectURL(small); setSrc(url) } else setSrc(blob.url)
    })
    let seen = null
    if (typeof IntersectionObserver === "function" && ref.current) {
      seen = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { seen.disconnect(); load() } }, { rootMargin: "400px" })
      seen.observe(ref.current)
    } else load()
    return () => { alive = false; seen?.disconnect(); if (url) URL.revokeObjectURL(url) }
  }, [blob.sha256, blob.url])
  return <img ref={ref} src={src || undefined} alt="" decoding="async" />
}
