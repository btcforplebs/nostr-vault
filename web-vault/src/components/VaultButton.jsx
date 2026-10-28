// The floating "Vault" button (iPhone VaultView+Layout), bottom right on the Vault tab, coloured as the iPhone colours
// it: by the app's own relay connections (net/connection-color.js). A tap opens the Vault Dashboard sheet. On a phone
// it sits above the tab bar; on a wide window, 20 px from the bottom as on an iPad.
import { useEffect, useState } from "preact/hooks"
import { pool } from "../net/pool.js"
import { STATES, poolState, withGrace } from "../net/connection-color.js"
import { dashboardHref, openDashboard } from "../net/dashboard-route.js"

/** The button's state, read from the pool every second. */
export function useConnectionState(every = 1000) {
  const [g, setG] = useState(() => withGrace(null, poolState(pool)))
  useEffect(() => {
    const t = setInterval(() => setG(prev => { const next = withGrace(prev, poolState(pool)); return next.shown === prev.shown && next.dropAt === prev.dropAt ? prev : next }), every)
    return () => clearInterval(t)
  }, [])
  return g.shown
}

export function VaultButton({ desk = false }) {
  const state = useConnectionState()
  const { text } = STATES[state]
  return (
    <a class={`vault-status ${state}${desk ? " desk" : ""}`} href={dashboardHref()} aria-label={`Vault Dashboard: ${text}`} title={text}
      onClick={e => { if (e.metaKey || e.ctrlKey || e.shiftKey) return; e.preventDefault(); openDashboard() }}>
      <LockStack /><b>Vault</b>
    </a>
  )
}

const LockStack = () => <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <path d="M7.4 3.2h9.2M5.8 5.6h12.4" /><rect x="3.8" y="8" width="16.4" height="13" rx="3.4" />
  <path d="M10.4 13.6v-1.2a1.6 1.6 0 0 1 3.2 0v1.2" /><rect x="9.4" y="13.4" width="5.2" height="4.2" rx="1" fill="currentColor" stroke="none" /></svg>
