// A long list drawn a page at a time, as the phone's Vault lists are (VaultView maxDisplayedItems, +50 when the last row
// shows): the first `shown` rows, then a marker below them. When the marker nears the screen, `onMore` is called with
// whether every row is already drawn, so the caller can read an older page.
import { useEffect, useRef } from "preact/hooks"
import { Spinner } from "./Loading.jsx"

/** Rows drawn at first, and how many more each time the end nears. */
export const FIRST_ROWS = 100
export const MORE_ROWS = 50

export function PagedList({ items, render, shown, onMore, busy = false, wrap: Wrap }) {
  const end = useRef(null)
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
