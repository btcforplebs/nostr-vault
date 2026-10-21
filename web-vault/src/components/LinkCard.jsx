// A link as a card (LinkPreviewCard.swift). When the card scrolls near, this browser fetches the page's OpenGraph
// itself (link-preview.js) and, if the site allows it, shows its og:image, site name, title, description and domain.
// Most sites refuse a cross-site read (CORS), and then it stays the iPhone's fallback: a link glyph, the domain and an
// arrow out. Opens in a new tab and never opens the card around it.
import { useEffect, useRef, useState } from "preact/hooks"
import { cachedPreview, canPreview, loadPreview } from "./link-preview.js"

const domain = url => { try { return new URL(url).hostname.replace(/^www\./, "") } catch { return url } }

export function LinkCard({ url }) {
  const ref = useRef(null)
  const [meta, setMeta] = useState(() => cachedPreview(url))
  const [badImage, setBadImage] = useState(false)
  useEffect(() => {
    setMeta(cachedPreview(url)); setBadImage(false)
    if (cachedPreview(url) !== undefined || !canPreview(url)) return
    let live = true
    const load = () => loadPreview(url).then(m => { if (live) setMeta(m) })
    if (!ref.current || !globalThis.IntersectionObserver) { load(); return () => { live = false } }
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); load() } }, { rootMargin: "300px" })
    io.observe(ref.current)
    return () => { live = false; io.disconnect() }
  }, [url])

  const stop = e => e.stopPropagation()
  if (meta?.title) {
    return (
      <a ref={ref} class="link-card link-card-rich" href={url} target="_blank" rel="noopener noreferrer" onClick={stop} title={url}>
        {meta.image && !badImage && <img class="link-card-image" src={meta.image} alt="" loading="lazy" referrerpolicy="no-referrer" onError={() => setBadImage(true)} />}
        <span class="link-card-text">
          {meta.siteName && <span class="link-card-site">{meta.siteName}</span>}
          <span class="link-card-title">{meta.title}</span>
          {meta.description && <span class="link-card-desc">{meta.description}</span>}
          <span class="link-card-host">{domain(url)}</span>
        </span>
      </a>
    )
  }
  return (
    <a ref={ref} class="link-card" href={url} target="_blank" rel="noopener noreferrer" onClick={stop} title={url}>
      <svg class="link-card-glyph" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true">
        <path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" />
      </svg>
      <span class="link-card-domain">{domain(url)}</span>
      <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 17 17 7M8 7h9v9" /></svg>
    </a>
  )
}
