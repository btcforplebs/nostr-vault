// A chat stays where you are reading (Messages UX check A3, 2026-11-18): it follows new messages to the bottom only
// while you are at the bottom, or when the newest is your own just sent. Scrolled up to read older ones, or after
// Open more, nothing moves you: the message you were reading stays where it was on screen, also in WebKit, which
// doesn't anchor scrolling by itself. The napplet (napplets/messages/index.html) follows the same rules.
import { useEffect, useLayoutEffect, useRef } from "preact/hooks"

/** How close to the bottom (px) still counts as reading the newest messages. */
export const NEAR_END_PX = 160

/** Does the chat follow to the bottom after this change? `atEnd`: the reader was at the bottom before it. */
export const followsEnd = (atEnd, newest, me) => !!atEnd || (!!newest && newest.from === me && !!newest.pending)

/**
 * For a chat drawn in the page's own scroll: `end` (a ref to the element after the last row) and `thread` (a ref to the
 * rows' box, each row with data-id). Call during render, before the rows draw; `key` resets it (a new conversation
 * opens at its newest).
 */
export function useChatScroll({ end, thread, rows, me, key }) {
  const atEnd = useRef(true)
  const anchor = useRef(null)
  const count = useRef(-1)
  const opened = useRef(undefined)
  if (opened.current !== key) { opened.current = key; atEnd.current = true; count.current = -1 } // before this draw, not after
  useEffect(() => {
    const look = () => { const el = end.current; if (el) atEnd.current = el.getBoundingClientRect().top <= innerHeight + NEAR_END_PX }
    addEventListener("scroll", look, { passive: true })
    return () => removeEventListener("scroll", look)
  }, [])
  // During render the page still shows the rows before this change: note the one being read and where it sits.
  const changed = rows.length !== count.current
  anchor.current = null
  if (changed && !atEnd.current && thread.current && typeof document !== "undefined") {
    const row = [...thread.current.querySelectorAll("[data-id]")].find(el => el.getBoundingClientRect().bottom > 0)
    if (row) anchor.current = { id: row.dataset.id, top: row.getBoundingClientRect().top }
  }
  const newest = rows.at(-1)
  useLayoutEffect(() => {
    if (rows.length === count.current) return
    count.current = rows.length
    if (followsEnd(atEnd.current, newest, me)) { end.current?.scrollIntoView?.({ block: "end" }); atEnd.current = true; return }
    const a = anchor.current
    const el = a && thread.current?.querySelector(`[data-id="${globalThis.CSS?.escape ? CSS.escape(a.id) : a.id}"]`)
    if (el) { const d = el.getBoundingClientRect().top - a.top; if (Math.abs(d) >= 1) scrollBy(0, d) }
  })
}
