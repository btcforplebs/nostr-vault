// New notes go in while the reader stays put (Logen 2026-11-04): with Auto-load on and the Feed scrolled past its first
// post, what arrives is put in above and the post being read keeps its height, as on the iPhone (FeedStayPut). The
// browser's own scroll anchoring isn't relied on: iPhone Safari has none. Same pin as Back from a thread (feed-tap.js).
import { onReaderScroll } from "./tap-line.js"

const PIN_MS = 5000 // held this long at most while the cards above draw (images, thread roots), or until the reader scrolls
/** Above this many pixels down, the reader is at the top: new notes just go in (the list grows upward). */
export const AT_TOP_PX = 80

const NOTE = "data-note-id"
const idOf = (el, attr) => el.getAttribute?.(attr) ?? (attr === NOTE ? el.dataset?.noteId : undefined) ?? null

/** The first post at least partly in view in `root` (the Feed's <main>), and its height: `{ id, top, attr }`, or null.
 *  `pane`: what the list scrolls in (FeedExtras feedScroller), null for the window. `attr`: what marks a row and holds
 *  its id (the Vault list's rows aren't notes: "data-row-id"). */
export function readingSpot(root, pane, { attr = NOTE } = {}) {
  const viewTop = pane ? pane.getBoundingClientRect().top : 0
  for (const el of root?.querySelectorAll?.(`[${attr}]`) ?? []) {
    const id = idOf(el, attr)
    if (!id) continue
    const r = el.getBoundingClientRect()
    if (r.bottom > viewTop) return { id, top: r.top, attr }
  }
  return null
}

/** How far to scroll so the post back at `spot.top` again: 0 when it is already there (or within a pixel). */
export const pinDelta = (spot, nowTop) => (Math.abs(nowTop - spot.top) >= 1 ? nowTop - spot.top : 0)

/**
 * Puts the post `spot` back at its height in `root` and holds it there as the cards above it grow, until the reader
 * scrolls or PIN_MS passes. -> a stop function.
 */
export function holdSpot(root, pane, spot, { ms = PIN_MS } = {}) {
  const sel = `[${spot.attr ?? NOTE}="${globalThis.CSS?.escape ? CSS.escape(spot.id) : spot.id}"]`
  const el = root?.querySelector?.(sel)
  if (!el) return () => {}
  const scroller = pane ?? globalThis
  const pin = () => {
    if (el.isConnected === false) return
    const d = pinDelta(spot, el.getBoundingClientRect().top)
    if (d) scroller.scrollBy?.({ top: d, behavior: "instant" })
  }
  pin()
  const grows = globalThis.ResizeObserver ? new ResizeObserver(pin) : null
  grows?.observe(root)
  let cap = 0, stopScroll = () => {}
  const done = () => { stopScroll(); grows?.disconnect(); clearTimeout(cap) }
  stopScroll = globalThis.addEventListener ? onReaderScroll(done) : () => {}
  cap = setTimeout(done, ms)
  cap?.unref?.() // node (the tests) only
  return done
}
