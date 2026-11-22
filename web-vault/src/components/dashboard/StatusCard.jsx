// The dashboard's status card (VaultDashboardView statusCard). In a browser the vault runs while the page does, so
// it is running (or still building who can reach you) whenever this card shows; its "…" menu has Restart, which
// reloads the page. No address (the browser's relay has no socket) and no Start or Stop: closing the tab stops it.
// In box mode (`box`) the card is the box's: running while it answers, its uptime, version and open connections,
// and no Restart until the box has a restart route (E5); reloading this page would not restart the box.
import { useEffect, useRef, useState } from "preact/hooks"

/** Why there is no Start or Stop here (parity #30), on the card itself. */
export const NO_START_STOP = "It runs while this page is open: no Start or Stop here. Closing the tab stops it."

/** "Up 3d 4h", "Up 2h 5m", "Up 7m" since `start` (ms). */
export function uptimeLine(start, now = Date.now()) {
  const s = Math.max(0, Math.floor((now - start) / 1000))
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60)
  return `Up ${d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`}`
}

/** "Up 3d 4h · version 1.0.0 · 2 connections" from the box's status and connections answers ({ value } | { error }). */
export function boxStatusLine(status, connections) {
  const s = status?.value, open = connections?.value?.open
  return [Number.isFinite(s?.uptime) ? uptimeLine(0, s.uptime * 1000) : null, s?.version ? `version ${s.version}` : null,
    Number.isFinite(open) ? `${open} ${open === 1 ? "connection" : "connections"}` : null].filter(Boolean).join(" · ")
}

/** The box's card: `box` = { status, connections }, each { value } | { error } | undefined (still asking). */
function BoxStatusCard({ box }) {
  const { status, connections } = box
  const answering = !!status?.value, failed = !!status?.error
  return (
    <div class="dash-status">
      <span class={`dash-dot ${answering ? "running" : failed ? "stopped" : ""}`} aria-hidden="true"><i /></span>
      <span class="dash-text">
        <span class="dash-status-title">{answering ? "Your box is running" : failed ? "Your box isn't answering" : "Asking your box…"}</span>
        {answering && <span class="dash-sub">{boxStatusLine(status, connections)}</span>}
        {failed && <span class="dash-sub">{status.error}</span>}
      </span>
    </div>
  )
}

export function StatusCard({ box, ...props }) {
  return box ? <BoxStatusCard box={box} /> : <BrowserStatusCard {...props} />
}

function BrowserStatusCard({ syncing = false, start = performance.timeOrigin, reload = () => location.reload() }) {
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
        <span class="dash-sub">{NO_START_STOP}</span>
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
