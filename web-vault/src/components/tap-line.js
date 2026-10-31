// The one line a tapped post's top lands on, in the Feed and on the thread screen, as the iPhone's TapLandingLine:
// 20 px under the top bar's buttons. The Feed's tap glides the opened post's top onto it; the thread screen puts the
// note you opened there, a reply as well as the root. One value on every phone; larger text makes a post taller, not
// its top lower. The page scrolls the document, so the line is a window y, and the bars are sticky, so it stays put.

export const TAP_GAP = 20

/** The line's y in the window: TAP_GAP under the lowest button in `bar` (the screen's sticky top bar), measured from
 *  where the bar sticks, so it is the same before the bar has reached the top of the screen. */
export function tapLine(bar, gap = TAP_GAP) {
  if (!bar) return gap
  const box = bar.getBoundingClientRect()
  const buttons = [...bar.querySelectorAll("button, a")].map(b => b.getBoundingClientRect()).filter(r => r.height > 0)
  const bottom = buttons.length ? Math.max(...buttons.map(r => r.bottom)) : box.bottom
  const stick = parseFloat(getComputedStyle(bar).top) || 0
  return Math.round(bottom - box.top + stick + gap)
}

/** The window scroll that puts a post whose top is at `top` (window y) on `line`. Never above the page top. */
export const landingScroll = (scrollY, top, line) => Math.max(0, Math.round(scrollY + top - line))

export const reducedMotion = () => !!globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches

/** Scrolls so `el`'s top sits on `line`: a glide, or a jump under Reduce Motion or when `instant`. */
export function landOn(el, line, { instant = false } = {}) {
  if (!el) return
  const top = landingScroll(scrollY, el.getBoundingClientRect().top, line)
  if (Math.abs(top - scrollY) < 1) return
  scrollTo({ top, behavior: instant || reducedMotion() ? "instant" : "smooth" })
}

/** Calls `fn` once the reader takes over the scroll (a touch, the wheel, a key); returns a stop. */
export function onReaderScroll(fn) {
  const evs = ["touchstart", "wheel", "keydown", "mousedown"]
  const on = () => { stop(); fn() }
  const stop = () => evs.forEach(e => removeEventListener(e, on, true))
  evs.forEach(e => addEventListener(e, on, { capture: true, passive: true }))
  return stop
}
