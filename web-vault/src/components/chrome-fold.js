// The phone layout's scroll-linked fold, as the iPhone does it (ChromeCollapse.swift, ScrollChromeModifier.swift):
// scrolling down folds the tab bar into a small avatar + compose capsule, fades the floating Post button and narrows the
// Feed's top bar pills to circles; scrolling up brings them back. The fold follows the finger 1:1 over one bar height
// (60px), so a half drag leaves the bars half folded. On release it settles to the nearer end, a fast fling commits to
// its direction at once, and the top of a list always shows the bars in full. The page scrolls the document (so
// Safari's own toolbar shrinks too); this only reads window scroll and touch events, it never moves the page.
//
// The value goes on <html> as --fold (0 = shown, 1 = folded) and data-fold ("open" | "folded", flipping at 0.5, as the
// iPhone's hit testing does); styles/chrome-fold.css draws the bars from them.

export const DISTANCE = 60 // px of scroll that folds the bars completely (ChromeCollapse.distance)
export const FLING = 400 // px/s: a release faster than this commits to its direction (ChromeCollapse.flingVelocity)
const IDLE_MS = 140 // no scroll for this long after the finger lifts = the scroll has stopped
// Motion.chrome: spring(response 0.38, damping 0.86); reduced motion: ease in-out over the response.
const RESPONSE = 0.38, DAMPING = 0.86

/** The fold's state machine, without the DOM: `onScroll(offset)`, `onTouch(down)`, `tick()` when idle. `set(p,
 *  animated)` is told every change. Mirrors ScrollChromeModifier's handle(offset:) and handle(phase:). */
export function foldTracker(set, { distance = DISTANCE, fling = FLING } = {}) {
  let progress = 0, phase = "idle", last = null, lastDir = 0, committed = false, velocity = 0, lastT = 0
  const ceiling = offset => offset / distance
  const apply = (p, animated) => { p = Math.min(Math.max(p, 0), 1); if (p !== progress || animated) { progress = p; set(p, animated) } }
  return {
    get progress() { return progress },
    get phase() { return phase },
    /** `offset`: the scroll position clamped to the scrollable range; `t`: ms timestamp. */
    onScroll(offset, t = 0) {
      const prev = last
      last = offset
      if (prev !== null && t > lastT) velocity = (offset - prev) / ((t - lastT) / 1000)
      lastT = t
      if ((phase === "interacting" || phase === "decelerating") && prev !== null && !committed) {
        const delta = offset - prev
        if (delta !== 0) lastDir = delta > 0 ? 1 : -1
        apply(Math.min(progress + delta / distance, ceiling(offset)), false)
        return
      }
      // Whatever moved the page (a jump to the top, new notes above), arriving near the top shows the bars.
      const cap = ceiling(offset)
      // A smooth scroll is followed frame by frame; a jump springs.
      if (progress > cap) apply(cap, progress - cap > 0.25)
    },
    onTouch(down) {
      if (down) { phase = "interacting"; committed = false; lastDir = 0; velocity = 0; return }
      if (phase !== "interacting") return
      phase = "decelerating"
      const canFold = ceiling(last ?? 0) >= 1
      if (Math.abs(velocity) >= fling && lastDir !== 0) { apply(lastDir > 0 && canFold ? 1 : 0, true); committed = true }
    },
    /** The scroll has stopped (the finger is up and nothing has moved for a moment): never leave the bars half folded. */
    idle() {
      if (phase === "interacting") return
      phase = "idle"
      committed = false
      const canFold = ceiling(last ?? 0) >= 1
      if (progress > 0 && progress < 1) apply(progress >= 0.5 && canFold ? 1 : 0, true)
    },
    /** Bars fully back: a new screen or tab, a tap on the folded avatar. */
    reset() { if (progress !== 0) apply(0, true) },
  }
}

/** A damped spring from `from` to `to`, called with each frame's value; returns a cancel. Reduced motion: ease in-out. */
export function spring(from, to, onFrame, { reduce = false, raf = requestAnimationFrame, caf = cancelAnimationFrame, now = () => performance.now() } = {}) {
  const w = 2 * Math.PI / RESPONSE, z = DAMPING, wd = w * Math.sqrt(1 - z * z), x0 = from - to
  const t0 = now()
  let id = 0
  const frame = () => {
    const t = (now() - t0) / 1000
    let v
    if (reduce) { const k = Math.min(t / RESPONSE, 1); v = from + (to - from) * (k < .5 ? 2 * k * k : 1 - 2 * (1 - k) ** 2); if (k >= 1) v = to }
    else { const x = Math.exp(-z * w * t) * (x0 * Math.cos(wd * t) + (z * w * x0 / wd) * Math.sin(wd * t)); v = Math.abs(x) < 0.001 ? to : to + x }
    onFrame(v)
    if (v !== to) id = raf(frame)
  }
  id = raf(frame)
  return () => caf(id)
}

let fold = null
const listeners = new Set()

/** Folded (true) or not, for the parts that swap what can be tapped; changes only at the halfway mark. */
export function onFoldedChange(fn) { listeners.add(fn); return () => listeners.delete(fn) }
export function isFolded() { return document.documentElement.dataset.fold === "folded" }
/** Bars fully back, animated (the folded avatar's tap). */
export function unfold() { fold?.reset() }

/** Starts the fold on this page (the phone layout); returns stop, which shows the bars and removes the markers. */
export function startChromeFold(win = window) {
  const root = win.document.documentElement
  const reduce = win.matchMedia?.("(prefers-reduced-motion: reduce)")
  let cancel = null, folded = false, idleTimer = 0
  const paint = p => {
    root.style.setProperty("--fold", String(Math.round(p * 1000) / 1000))
    const now = p >= 0.5
    if (now !== folded) { folded = now; root.dataset.fold = now ? "folded" : "open"; listeners.forEach(f => f(now)) }
  }
  const tracker = foldTracker((p, animated) => {
    cancel?.(); cancel = null
    if (!animated) return paint(p)
    const from = parseFloat(root.style.getPropertyValue("--fold")) || 0
    cancel = spring(from, p, paint, { reduce: !!reduce?.matches })
  })
  fold = tracker
  const offset = () => {
    const max = Math.max(0, root.scrollHeight - win.innerHeight)
    return Math.min(Math.max(win.scrollY, 0), max) // Safari's rubber band past either end moves nothing
  }
  const settleLater = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => tracker.idle(), IDLE_MS) }
  const onScroll = () => { tracker.onScroll(offset(), performance.now()); if (tracker.phase !== "interacting") settleLater() }
  const down = e => { if (e.touches?.length > 1) return; clearTimeout(idleTimer); tracker.onTouch(true) }
  const up = e => { if (e.touches?.length) return; tracker.onTouch(false); settleLater() }
  // A mouse wheel or trackpad on a narrow window: each burst of wheel events is one drag.
  const wheel = () => { if (tracker.phase !== "interacting") tracker.onTouch(true); clearTimeout(idleTimer); idleTimer = setTimeout(() => { tracker.onTouch(false); tracker.idle() }, IDLE_MS) }
  // A new screen starts with the bars open (BottomTabBar onChange(selectedTab) chrome.reset()).
  const route = () => tracker.reset()
  const opts = { passive: true }
  win.addEventListener("scroll", onScroll, opts)
  win.addEventListener("touchstart", down, opts)
  win.addEventListener("touchend", up, opts)
  win.addEventListener("touchcancel", up, opts)
  win.addEventListener("wheel", wheel, opts)
  win.addEventListener("hashchange", route)
  paint(0)
  root.dataset.fold = "open"
  tracker.onScroll(offset(), performance.now())
  return () => {
    cancel?.(); clearTimeout(idleTimer)
    win.removeEventListener("scroll", onScroll, opts)
    win.removeEventListener("touchstart", down, opts)
    win.removeEventListener("touchend", up, opts)
    win.removeEventListener("touchcancel", up, opts)
    win.removeEventListener("wheel", wheel, opts)
    win.removeEventListener("hashchange", route)
    if (fold === tracker) fold = null
    if (folded) { folded = false; listeners.forEach(f => f(false)) }
    root.style.removeProperty("--fold")
    delete root.dataset.fold
  }
}
