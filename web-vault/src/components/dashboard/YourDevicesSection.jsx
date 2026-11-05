// "Your devices" (plan §6), under the status card: the user's own devices this browser knows, each with its green dot
// when it is on the mesh (my-devices.js, as the Your space panel), and the two ways to link one more by two scans
// (PairDevice.jsx): show this browser's code, or scan the other device's.
import { useEffect, useState } from "preact/hooks"
import { Section } from "./parts.jsx"
import { loadMyDevices, deviceStatus, statusLine, REFRESH_MS } from "../../desktop/space/my-devices.js"
import { deviceRows, pairedDevices } from "../../net/pair-devices.js"
import "../../styles/my-devices.css"
import "../../styles/pair.css"

export function YourDevicesSection({ ctx, onPair, load = loadMyDevices }) {
  const [data, setData] = useState(null)
  useEffect(() => {
    let alive = true
    const look = () => load(ctx).then(d => { if (alive) setData(d) }).catch(() => { if (alive) setData(d => d ?? { devices: [], adverts: new Map(), checked: false }) })
    look()
    const timer = setInterval(look, REFRESH_MS)
    return () => { alive = false; clearInterval(timer) }
  }, [ctx.session.pubkey])
  const now = Math.floor(Date.now() / 1000)
  const rows = deviceRows(data?.devices, pairedDevices()).map(d => ({ d, s: deviceStatus(data.adverts.get(d.hex), now, { checked: data.checked }) }))
  const onMesh = rows.filter(r => r.s.state === "online" || r.s.state === "connected").length
  return (
    <Section title="Your devices" detail={rows.length ? `${onMesh} of ${rows.length} on the mesh` : undefined}>
      <div class="my-devices">
        {!data ? <div class="dash-row"><span class="dash-sub">Checking the mesh…</span></div>
          : !rows.length ? <div class="dash-row"><span class="dash-sub">No devices linked yet. Link your phone, Mac or home vault to this browser vault.</span></div>
          : rows.map(({ d, s }) => (
            <div key={d.hex} class="dash-row">
              <span class={`md-dot ${s.state}`} role="img" aria-label={s.state} />
              <span class="dash-text"><span class="dash-title">{d.title}</span><span class="dash-sub">{statusLine(s, now)}</span></span>
            </div>
          ))}
      </div>
      <div class="pair-device-actions">
        <button type="button" class="dash-button" onClick={() => onPair("show")}>Show my code</button>
        <button type="button" class="dash-button" onClick={() => onPair("scan")}>Scan a code</button>
      </div>
    </Section>
  )
}
