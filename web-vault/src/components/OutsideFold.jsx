// One line, "Show N from outside your web", that opens onto what it folds (net/outside-fold.js). Closed again when
// `resetKey` changes (a new search, another account). Draws nothing while there is nothing outside. `underPost`: a
// fold under a post or in a feed, which the "Show 'Outside your web' under posts" switch takes away (outside-switch.js).
import { useEffect, useState } from "preact/hooks"
import { outsideLabel } from "../net/outside-fold.js"
import { showsOutside, onShowsOutside } from "../net/outside-switch.js"
if (import.meta.env) import("../styles/outside-fold.css")

/** The switch's state, redrawn when it moves. */
export function useShowsOutside() {
  const [on, setOn] = useState(showsOutside)
  useEffect(() => onShowsOutside(() => setOn(showsOutside())), [])
  return on
}

export function OutsideFold({ count, resetKey, underPost = false, children }) {
  const [open, setOpen] = useState(false)
  const shows = useShowsOutside()
  useEffect(() => setOpen(false), [resetKey])
  if (!count || (underPost && !shows)) return null
  return (
    <>
      <button type="button" class="outside-fold-toggle" aria-expanded={open} onClick={() => setOpen(v => !v)}>{outsideLabel(count, open)}</button>
      {open && <div class="outside-fold">{children}</div>}
    </>
  )
}
