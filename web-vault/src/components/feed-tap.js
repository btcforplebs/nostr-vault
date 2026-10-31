// The Feed's open post and where the reader was, kept for the page load: the phone's Feed screen is unmounted while a
// thread is open, and Back draws it again. As on the iPhone, Back finds the list where it was left, with the post that
// was opened still open.
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks"
import { unfold } from "./chrome-fold.js"
import { landOn, onReaderScroll, tapLine } from "./tap-line.js"

const PIN_MS = 5000 // the spot is held this long at most as the list draws again
let kept = { openId: null }
const spots = new Map() // feed key -> { id, top }: the first post at or under the tap line, and its window y
export const forgetFeedTap = () => { kept = { openId: null }; spots.clear() } // tests

/** Is a post open in place in the Feed on screen now? New notes don't go in above it while one is (the iPhone holds auto-load). */
export const feedPostOpen = () => !!kept.openId && !!globalThis.document?.querySelector("[data-tap-open]")

const head = () => document.querySelector(".feed-head")
const rowTop = id => document.querySelector(`.condensed[data-note-id="${CSS.escape(id)}"]`)?.getBoundingClientRect().top

/**
 * The open post's id and the tap that opens one. A tap holds the tapped line where it was tapped while the post that
 * was open above it closes (the iPhone's heldRow), then glides the opened post's top onto the tap line, with the bars
 * back (TapLandingLine, FeedView glideToLandingLine). On the desktop layout the list scrolls in its own pane: no glide.
 */
export function useFeedTap() {
  const [openId, setOpenId] = useState(kept.openId)
  const tap = useRef(null)
  const open = id => {
    tap.current = globalThis.document && !document.querySelector(".desk-app") ? { id, top: rowTop(id) } : null
    kept = { openId: id }
    setOpenId(id)
  }
  useLayoutEffect(() => {
    const t = tap.current
    tap.current = null
    const el = t && document.querySelector("[data-tap-open]")
    if (!el) return
    if (t.top != null) scrollTo({ top: scrollY + el.getBoundingClientRect().top - t.top, behavior: "instant" })
    unfold()
    const raf = requestAnimationFrame(() => landOn(el, tapLine(head())))
    return () => cancelAnimationFrame(raf)
  }, [openId])
  return [openId, open]
}

/**
 * Keeps where the reader is in the feed `key` (on the phone layout) and puts it back when the Feed is drawn again:
 * the first post at or under the tap line, at the same height. `ready`: the rows are drawn.
 */
export function useFeedSpot(key, ready) {
  // The spot to put back, taken once per feed shown; nothing is saved over it until it has been put back.
  const want = useRef({ key: null, spot: null, pinning: false })
  if (want.current.key !== key) want.current = { key, spot: spots.get(key) ?? null, pinning: false }
  // A thread's root can draw a moment after the rows: wait that long for the post, then give up on it.
  useEffect(() => {
    const w = want.current
    const t = setTimeout(() => { if (w.spot) w.spot = null }, PIN_MS)
    return () => clearTimeout(t)
  }, [key])
  useEffect(() => {
    const w = want.current, p = w.spot
    if (!ready || !p || document.querySelector(".desk-app")) return
    const el = document.querySelector(`main.screen [data-note-id="${CSS.escape(p.id)}"]`)
    if (!el) return
    w.spot = null
    w.pinning = true
    // Put back each time the list above it grows (thread roots and images landing), until the reader scrolls.
    const pin = () => { const d = el.getBoundingClientRect().top - p.top; if (el.isConnected && Math.abs(d) >= 1) scrollTo({ top: scrollY + d, behavior: "instant" }) }
    pin()
    const grows = globalThis.ResizeObserver ? new ResizeObserver(pin) : null
    grows?.observe(el.closest("main") ?? document.body)
    const done = () => { stop(); grows?.disconnect(); clearTimeout(cap); w.pinning = false }
    const stop = onReaderScroll(done)
    const cap = setTimeout(done, PIN_MS)
  })
  useEffect(() => {
    if (!globalThis.addEventListener) return
    let raf = 0
    const save = () => {
      raf = 0
      const w = want.current
      if (w.spot || w.pinning || !/^#\/?(feed)?(\?|$)/.test(location.hash) || document.querySelector(".desk-app")) return
      const line = tapLine(head())
      const row = [...document.querySelectorAll("main.screen [data-note-id]")].find(e => e.getBoundingClientRect().bottom > line)
      if (row) spots.set(key, { id: row.dataset.noteId, top: row.getBoundingClientRect().top })
    }
    const on = () => { if (!raf) raf = requestAnimationFrame(save) }
    addEventListener("scroll", on, { passive: true })
    return () => { removeEventListener("scroll", on); cancelAnimationFrame(raf) }
  }, [key])
}
