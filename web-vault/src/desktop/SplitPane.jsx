// The left column (design: "Your space", 2026-11-02): one page at a time, as on the iPhone. An open note,
// conversation or thread covers the list, with ‹ Back; Back finds the list where it was left.
import { useLayoutEffect, useRef } from "preact/hooks"

export function SplitPane({ list, detail, onBack }) {
  const listEl = useRef()
  const scroll = useRef(0)
  // The list is hidden under an open page, and a hidden element forgets its scroll: note it on the way in and put it
  // back on the way out.
  useLayoutEffect(() => {
    const el = listEl.current
    if (!el) return
    if (detail) return
    el.scrollTop = scroll.current
    const f = () => { scroll.current = el.scrollTop }
    el.addEventListener("scroll", f, { passive: true })
    return () => el.removeEventListener("scroll", f)
  }, [!!detail])
  return (
    <div class="desk-split single">
      <div class="desk-list" ref={listEl} hidden={!!detail}>{list}</div>
      {detail && (
        <div class="desk-detail slide">
          <div class="desk-back"><button type="button" class="small" onClick={onBack}>‹ Back</button></div>
          {detail}
        </div>
      )}
    </div>
  )
}
