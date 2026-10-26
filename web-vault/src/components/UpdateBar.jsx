// The bar a new build shows once its service worker is waiting (src/sw-update.js). A tap reloads into it.
import { useEffect, useState } from "preact/hooks"
import { onUpdateReady, applyUpdate } from "../sw-update.js"
import "../styles/update-bar.css"

export function UpdateBar() {
  const [ready, setReady] = useState(false)
  const [busy, setBusy] = useState(false)
  useEffect(() => onUpdateReady(setReady), [])
  if (!ready) return null
  return (
    <button class="update-bar" role="status" disabled={busy} onClick={() => { setBusy(true); applyUpdate() }}>
      {busy ? "Reloading…" : "Update ready, tap to reload"}
    </button>
  )
}
