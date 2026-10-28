// The dashboard's status card (VaultDashboardView statusCard). In a browser the vault runs while the page does, so
// it is running (or still building who can reach you) whenever this card shows; its "…" menu has Restart, which
// reloads the page. No address (the browser's relay has no socket) and no Start or Stop: closing the tab stops it.
import { useEffect, useRef, useState } from "preact/hooks"

/** "Up 3d 4h", "Up 2h 5m", "Up 7m" since `start` (ms). */
export function uptimeLine(start, now = Date.now()) {
  const s = Math.max(0, Math.floor((now - start) / 1000))
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
  return `Up ${d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`}`
}

export function StatusCard({ syncing = false, start = performance.timeOrigin, reload = () => location.reload() }) {
  const [now, setNow] = useState(Date.now())
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(t) }, [])
  const [menu, setMenu] = useState(false)
  const box = useRef(null)
  useEffect(() => {
    if (!menu) return
    const off = e => { if (!box.current?.contains(e.target)) setMenu(false) }
    addEventListener("pointerdown", off)
    return () => removeEventListener("pointerdown", off)
  }, [menu])
  return (
    <div class="dash-status">
      <span class="dash-dot running" aria-hidden="true"><i /></span>
      <span class="dash-text">
        <span class="dash-status-title">Your vault is running</span>
        <span class="dash-sub">{syncing ? "Updating who can reach you…" : uptimeLine(start, now)}</span>
      </span>
      <span class="dash-menu" ref={box}>
        <button type="button" class="dash-more" aria-label="Vault controls" aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(m => !m)}>
          <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true"><circle cx="5" cy="12" r="1.8" /><circle cx="12" cy="12" r="1.8" /><circle cx="19" cy="12" r="1.8" /></svg>
        </button>
        {menu && <div class="dash-menu-list" role="menu"><button role="menuitem" onClick={reload}>Restart</button></div>}
      </span>
    </div>
  )
}
