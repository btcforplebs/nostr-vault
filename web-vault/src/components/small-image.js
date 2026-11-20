// Small pictures drawn small (perf audit 2026-11-20 L2, L3). An <img> keeps its source decoded at natural size: a
// 4000 px photo in a 40 px avatar holds ~48 MB, and 84 feed images held 754 MB for 5 MB of pixels shown. An animated
// GIF also repaints on the main thread for as long as it is on screen (3–28 % of a core each). So an avatar or a feed
// picture is fetched once, decoded off the main thread, drawn at the size it is shown (times the screen's pixel
// ratio) and kept as a small still image; an animated one plays only while hovered or focused, and the lightbox still
// opens the original. Where that can't be done (no CORS on the server, no createImageBitmap) the caller draws the
// original as before.
import { useEffect, useRef, useState } from "preact/hooks"

/** Done stills per url and size: { src, animated }; src null = draw the original. Oldest dropped past MAX. */
const done = new Map()
const pending = new Map()
const MAX = 600

const animatedBytes = (type, b) => {
  if (type === "image/gif") return true
  const text = String.fromCharCode(...b.subarray(0, 256))
  if (type === "image/webp") return text.includes("ANIM")
  if (type === "image/png" || type === "image/apng") return text.includes("acTL")
  return false
}

/** How far a w×h picture must shrink for a box×box-sized slot: "contain" fits inside, "cover" fills it. ≤ 1. */
export function scaleFor(w, h, box, fit) {
  const s = fit === "cover" ? Math.max(box.w / w, box.h / h) : Math.min(box.w / w, box.h / h)
  return Math.min(1, s)
}

/** -> { src, animated }: src a blob: URL of the small still, or null to draw `url` as it is. */
async function makeStill(url, box, fit) {
  if (typeof createImageBitmap !== "function" || typeof OffscreenCanvas !== "function") return { src: null, animated: false }
  const res = await fetch(url, { mode: "cors", credentials: "omit", referrerPolicy: "no-referrer" })
  if (!res.ok) throw new Error(`HTTP ${res.status}`)
  const blob = await res.blob()
  const animated = animatedBytes(blob.type, new Uint8Array(await blob.slice(0, 256).arrayBuffer()))
  const bmp = await createImageBitmap(blob)
  try {
    const s = scaleFor(bmp.width, bmp.height, box, fit)
    if (s >= 1 && !animated) return { src: null, animated }
    const w = Math.max(1, Math.round(bmp.width * s)), h = Math.max(1, Math.round(bmp.height * s))
    const c = new OffscreenCanvas(w, h)
    const g = c.getContext("2d")
    g.imageSmoothingQuality = "high"
    g.drawImage(bmp, 0, 0, w, h)
    const out = await c.convertToBlob({ type: "image/webp", quality: 0.85 })
    return { src: URL.createObjectURL(out), animated }
  } finally { bmp.close() }
}

function remember(key, v) {
  done.set(key, v)
  while (done.size > MAX) {
    const [k, old] = done.entries().next().value
    done.delete(k)
    if (old.src) URL.revokeObjectURL(old.src)
  }
}

/** The still for `url` in a box (CSS px; the pixel ratio is applied here) -> promise of { src, animated }. A failed
 *  fetch (CORS, 404) is { src: null }: the caller draws the original, which keeps its own error and mesh handling. */
export function stillOf(url, box, fit) {
  const dpr = Math.min(3, Math.max(1, globalThis.devicePixelRatio || 1))
  const px = { w: Math.ceil(box.w * dpr), h: Math.ceil(box.h * dpr) }
  const key = `${fit}|${px.w}x${px.h}|${url}`
  if (done.has(key)) { const v = done.get(key); done.delete(key); done.set(key, v); return Promise.resolve(v) }
  if (!pending.has(key)) {
    pending.set(key, makeStill(url, px, fit).catch(() => ({ src: null, animated: false }))
      .then(v => { pending.delete(key); remember(key, v); return v }))
  }
  return pending.get(key)
}

const httpUrl = u => typeof u === "string" && /^https:\/\//i.test(u)

/**
 * What an <img> for `url` should show. `box`: { w, h } in CSS px, or a function of the element (measured on first
 * sight); `fit`: "cover" | "contain"; `near`: false holds the fetch until it is (lazy, as loading="lazy").
 * -> { src, ready, animated, hover: { onPointerEnter, onPointerLeave, onFocus, onBlur }, ref }
 * `ready` false: nothing decided yet (draw a blank of the same size, not the original). An animated picture shows
 * its original while hovered or focused.
 */
export function useSmallSrc(url, { box, fit = "cover", lazy = true } = {}) {
  const ok = httpUrl(url)
  const [got, setGot] = useState(null) // { url, src, animated }
  const [live, setLive] = useState(false)
  const ref = useRef()
  useEffect(() => {
    if (!ok) return
    let gone = false, io = null
    const go = () => {
      const el = ref.current
      const b = typeof box === "function" ? box(el) : box
      if (!b?.w || !b?.h) { setGot({ url, src: null, animated: false }); return }
      stillOf(url, b, fit).then(v => { if (!gone) setGot({ url, ...v }) })
    }
    if (!lazy || typeof IntersectionObserver !== "function" || !ref.current) go()
    else {
      io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); io = null; go() } }, { rootMargin: "800px" })
      io.observe(ref.current)
    }
    return () => { gone = true; io?.disconnect() }
  }, [url, ok])
  const mine = got?.url === url ? got : null
  const on = () => setLive(true), off = () => setLive(false)
  const hover = mine?.animated ? { onPointerEnter: on, onPointerLeave: off, onFocus: on, onBlur: off } : {}
  if (!ok) return { src: url, ready: true, animated: false, hover, ref }
  if (!mine) return { src: null, ready: false, animated: false, hover, ref }
  return { src: mine.src && !(mine.animated && live) ? mine.src : url, ready: true, animated: mine.animated, hover, ref }
}
