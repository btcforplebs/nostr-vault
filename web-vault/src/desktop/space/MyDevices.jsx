// My devices: a "Your space" panel. Each of the user's own devices (mobile and desktop vaults from their media server list, vaults
// paired in Who Can Reach You) with whether it is on the mesh and when it last was (my-devices.js), asked again every
// REFRESH_MS while the page is in front and not while it is hidden (auto-look.js). Twin of the iPad's
// MyDevicesPanel.swift. Reads only.
import { useEffect, useState } from "preact/hooks"
import { lookInFront } from "../../components/auto-look.js"
import { loadMyDevices, deviceStatus, statusLine, deviceName, REFRESH_MS, MESH_HEADER } from "./my-devices.js"
import "../../styles/my-devices.css"

export function MyDevices({ ctx, open: shown = true, tools = null }) {
  const [data, setData] = useState(null)
  useEffect(() => {
    let alive = true
    const look = () => loadMyDevices(ctx).then(d => { if (alive) setData(d) }).catch(() => { if (alive) setData(d => d ?? { devices: [], adverts: new Map(), checked: false }) })
    look()
    const stop = lookInFront(look, { every: REFRESH_MS })
    return () => { alive = false; stop() }
  }, [ctx.session.pubkey])
  const now = Math.floor(Date.now() / 1000)
  const rows = (data?.devices ?? []).map(d => ({ d, s: deviceStatus(data.adverts.get(d.hex), now, { checked: data.checked }) }))
  const onMesh = rows.filter(r => r.s.state === "online" || r.s.state === "connected").length
  return (
    <section class={shown ? "sp-panel my-devices" : "sp-panel my-devices closed"} aria-label="My devices">
      <header class="sp-head">
        <span class="sp-icon" aria-hidden="true">📱</span>
        <h3>My devices</h3>
        {rows.length > 0 && <span class="md-count" role="img" aria-label={`${onMesh} of ${rows.length} on the mesh`}>{onMesh}/{rows.length}</span>}
        {tools}
      </header>
      <ul class="sp-rows">
        {!data ? <li class="sp-empty">Checking the mesh…</li>
          : !rows.length ? <li class="sp-empty">No devices yet. Pair a vault in Who Can Reach You, or set up a mobile or desktop vault in Nostr Vault.</li>
          : [<li key="header" class="sp-empty md-header">{MESH_HEADER}</li>, ...rows.map(({ d, s }) => (
            <li key={d.hex} class="sp-row md-row">
              <span class={`md-dot ${s.state}`} role="img" aria-label={s.state} />
              <span class="sp-row-main">
                <span class="sp-row-who">{deviceName(d)}</span>
                <span class="sp-row-text">{statusLine(s, now)}</span>
              </span>
            </li>
          ))]}
      </ul>
      <a class="sp-foot" href="#/relay">Who Can Reach You ›</a>
    </section>
  )
}
