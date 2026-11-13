// One line, "Show N from outside your web", that opens onto what it folds (net/outside-fold.js). Closed again when
// `resetKey` changes (a new search, another account). Draws nothing while there is nothing outside.
import { useEffect, useState } from "preact/hooks"
import { outsideLabel } from "../net/outside-fold.js"
if (import.meta.env) import("../styles/outside-fold.css")

export function OutsideFold({ count, resetKey, children }) {
  const [open, setOpen] = useState(false)
  useEffect(() => setOpen(false), [resetKey])
  if (!count) return null
  return (
    <>
      <button type="button" class="outside-fold-toggle" aria-expanded={open} onClick={() => setOpen(v => !v)}>{outsideLabel(count, open)}</button>
      {open && <div class="outside-fold">{children}</div>}
    </>
  )
}
