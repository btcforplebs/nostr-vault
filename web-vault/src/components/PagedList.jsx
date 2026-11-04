// A long list drawn a page at a time, as the phone's Vault lists are (VaultView maxDisplayedItems, +50 when the last row
// shows): the first `shown` rows, then a marker below them. When the marker nears the screen, `onMore` is called with
// whether every row is already drawn, so the caller can read an older page.
// Rows that go in above the ones drawn (new posts, now that the Vault fills in on its own) grow the window by as many:
// the rows below stay drawn, so a photo loading in one is not cancelled and started again from zero when it is
// scrolled back to (MediaImage stops a read once its row leaves the page; Logen's slow Vault pictures, 2026-11-04).
import { useEffect, useRef } from "preact/hooks"
import { Spinner } from "./Loading.jsx"

/** Rows drawn at first, and how many more each time the end nears. */
export const FIRST_ROWS = 100
export const MORE_ROWS = 50

/** What tells one row from another across draws: the ids the Vault's lists carry (a row's id, a photo's url, a
 *  follower's pubkey). */
export const rowKey = it => it?.id ?? it?.url ?? it?.pubkey ?? null

/**
 * How many rows to draw: `shown` (the caller's window), plus the rows that went in above the first one drawn since
 * the window was last set. `was`: the last draw ({ shown, first, extra }), updated in place. A list whose first row
 * drawn is gone (another list, a filter) starts again at `shown`; so does a smaller `shown` (the caller reset it).
 */
export function windowRows(items, shown, was) {
  const first = items.length ? rowKey(items[0]) : null
  let extra = 0
  if (was.first != null && shown >= was.shown) {
    const at = was.first === first ? 0 : items.findIndex(it => rowKey(it) === was.first)
    if (at >= 0) extra = was.extra + at
  }
  Object.assign(was, { shown, first, extra })
  return shown + extra
}

export function PagedList({ items, render, shown: asked, onMore, busy = false, wrap: Wrap }) {
  const end = useRef(null)
  const was = useRef({ shown: asked, first: null, extra: 0 })
  const shown = windowRows(items, asked, was.current)
  const atEnd = shown >= items.length
  const more = useRef(onMore)
  more.current = onMore
  // Made again after each page: it reports at once, so a page that leaves the marker in view asks for the next.
  useEffect(() => {
    const el = end.current
    if (!el || busy || typeof IntersectionObserver === "undefined") return
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) more.current(atEnd) }, { rootMargin: "600px 0px" })
    io.observe(el)
    return () => io.disconnect()
  }, [shown, items.length, busy])
  const rows = items.slice(0, shown).map(render)
  return <>
    {Wrap ? <Wrap>{rows}</Wrap> : rows}
    <div ref={end} class="paged-end" aria-hidden={!busy || undefined}>{busy && <div class="status-line"><Spinner /> Loading older…</div>}</div>
  </>
}
