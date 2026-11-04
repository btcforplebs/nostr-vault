// The Feed's states and controls around the notes, as on the iPhone: placeholder rows while the first notes load
// (FeedNoteSkeletonRow), the empty Following state (FeedView+EmptyStates), the Replies / Reposts menu
// (FeedView+ToolbarMenu), and Older that loads on its own as it scrolls in.
import { useEffect, useRef, useState } from "preact/hooks"

/** `label` says what is loading, for screen readers (and the tests). */
export function SkeletonRows({ count = 5, label = "Loading notes…" }) {
  return <div class="feed-skeletons" aria-busy="true">
    <span class="sr-only">{label}</span>
    {Array.from({ length: count }, (_, i) => (
      <div class="note skeleton" key={i} aria-hidden="true">
        <div class="sk-head"><span class="sk-avatar" /><span class="sk-lines"><span class="sk-bar" style="width: 100px" /><span class="sk-bar" style="width: 60px; height: 10px" /></span></div>
        <span class="sk-bar" /><span class="sk-bar" /><span class="sk-bar" style="width: 60%" />
      </div>
    ))}
  </div>
}

export function EmptyFollowing() {
  return <div class="feed-empty">
    <svg viewBox="0 0 24 24" width="56" height="56" fill="none" stroke="url(#nv-empty-grad)" stroke-width="1" stroke-linecap="round" aria-hidden="true">
      <defs><linearGradient id="nv-empty-grad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="var(--accent)" /><stop offset="1" stop-color="var(--accent-light)" /></linearGradient></defs>
      <circle cx="11" cy="12" r="9" /><circle cx="11" cy="10" r="3" /><path d="M5.5 18.5a6.5 6.5 0 0 1 11 0M19 3v4M17 5h4" />
    </svg>
    <h3>No Following Feed</h3>
    <p>Follow npubs on Nostr to see their posts here</p>
  </div>
}

/** What a list scrolls in: on the desktop layout its pane (desktop.css .desk-list: the page itself never scrolls
 *  there), else null for the window, as on the phone. `el`: any element inside the list. */
export const feedScroller = el => el?.closest?.(".desk-list") ?? null
/** How far `pane` (feedScroller) is scrolled; the window's scrollY when it is null. */
export const scrollTopOf = pane => (pane ? pane.scrollTop : globalThis.scrollY ?? 0)
/** Back to the top of `pane` (feedScroller), or of the window when it is null. */
export const scrollToTop = (pane, behavior = "smooth") => (pane ?? globalThis).scrollTo?.({ top: 0, behavior })

/** Reposts and Replies (not on Global, which has none, as on the iPhone). */
export function FilterMenu({ filters, onChange, replies = true }) {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!ref.current?.contains(e.target)) setOpen(false) }
    const esc = e => { if (e.key === "Escape") setOpen(false) }
    addEventListener("pointerdown", away); addEventListener("keydown", esc)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", esc) }
  }, [open])
  const flip = k => onChange({ ...filters, [k]: !filters[k] })
  const item = (k, label) => (
    <button type="button" role="menuitemcheckbox" aria-checked={filters[k]} class={filters[k] ? "on" : ""} onClick={() => flip(k)}>
      <span class="check" aria-hidden="true">{filters[k] ? "✓" : ""}</span>{label}
    </button>
  )
  return <span class="feed-filter" ref={ref}>
    <button type="button" class="small" aria-haspopup="menu" aria-expanded={open} aria-label="Feed options" title="Feed options" onClick={() => setOpen(!open)}>
      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 6h16M7 12h10M10 18h4" /></svg>
    </button>
    {open && <div class="feed-filter-menu" role="menu">
      {item("reposts", "Reposts")}
      {replies && item("replies", "Replies")}
    </div>}
  </span>
}

/** Older: loads by itself when it scrolls into view (the iPhone loads at the end of the list), and stays a button for
 *  keyboards and for when the observer can't. `state`: "" | "busy" | "end" | an error message. */
export function OlderButton({ onOlder, state = "" }) {
  const ref = useRef(null), load = useRef(onOlder)
  load.current = onOlder
  const busy = state === "busy", end = state === "end"
  // Watches again after each load, so a page that leaves Older still in view loads the next; never after an error.
  useEffect(() => {
    if (!ref.current || state || !globalThis.IntersectionObserver) return
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) load.current() }, { rootMargin: "600px 0px" })
    io.observe(ref.current)
    return () => io.disconnect()
  }, [state])
  if (end) return <p class="feed-end muted">No older notes</p>
  return <>
    {state && !busy && <p class="feed-end muted">Couldn't load older notes ({state})</p>}
    <button ref={ref} class="more" onClick={busy ? undefined : onOlder} aria-busy={busy || undefined} disabled={busy}>
      {busy ? <><span class="spinner" aria-hidden="true" /> Loading older notes…</> : state ? "Try again" : "Older notes"}
    </button>
  </>
}

/** Pull down from the top of the page on a touch screen to refresh (the iPhone's .refreshable). Returns how far the
 *  pull has gone, 0..1, for the indicator. */
export function usePullToRefresh(onRefresh, { enabled = true, distance = 80 } = {}) {
  const [pull, setPull] = useState(0)
  const run = useRef(onRefresh)
  run.current = onRefresh
  useEffect(() => {
    if (!enabled || !("ontouchstart" in globalThis)) return
    let start = null, amount = 0
    const down = e => { start = scrollY <= 0 && e.touches.length === 1 ? e.touches[0].clientY : null; amount = 0 }
    const move = e => {
      if (start === null) return
      amount = Math.max(0, Math.min(1, (e.touches[0].clientY - start) / distance))
      setPull(amount)
    }
    const up = () => { if (start !== null && amount >= 1) run.current(); start = null; amount = 0; setPull(0) }
    addEventListener("touchstart", down, { passive: true }); addEventListener("touchmove", move, { passive: true }); addEventListener("touchend", up)
    return () => { removeEventListener("touchstart", down); removeEventListener("touchmove", move); removeEventListener("touchend", up) }
  }, [enabled, distance])
  return pull
}

export function PullIndicator({ pull, busy }) {
  if (!pull && !busy) return null
  return <div class={`pull-indicator${busy ? " busy" : ""}`} style={`--pull: ${busy ? 1 : pull}`} aria-hidden="true">
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v4h-4" /></svg>
  </div>
}
