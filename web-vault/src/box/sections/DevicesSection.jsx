// Box screen, My Devices: this box's own address and the owner's devices that have reached it. `state`: the devices
// call's { value } | { error }.
import { Part, Row } from "./Parts.jsx"
import { ago, shortNpub } from "../format.js"

const ROLE = { mac: "Desktop vault · full history", phone: "Phone", homeVault: "Mobile vault · new posts", browser: "Browser vault" }

export function DevicesSection({ state }) {
  const devices = state?.value
  return (
    <Part title="My Devices" state={state}>
      {devices && <Devices devices={devices} />}
    </Part>
  )
}

function Devices({ devices }) {
  const box = devices.box ?? {}
  const list = Array.isArray(devices.devices) ? devices.devices : []
  return (
    <div class="settings-rows">
      <Row label="This box" value={shortNpub(box.npub)} copy={box.npub} />
      <p class="muted small box-pad">To approve it, open My Devices on your phone or Mac and add this box as a mobile vault (Mobile vault · new posts). The box has no key of yours; it only stores and passes on what you sign.</p>
      {list.length === 0 && <p class="muted small box-pad">No devices of yours have reached the box yet.</p>}
      {list.map(d => (
        <div key={d.npub} class="settings-row box-row">
          <span class="settings-title">{d.name?.trim() || ROLE[d.role] || "Device"}<span class="muted small box-sub">{[d.name?.trim() && ROLE[d.role], Number.isFinite(d.lastSeen) && `seen ${ago(d.lastSeen)}`].filter(Boolean).join(" · ")}</span></span>
          <span class={`box-value ${d.approved ? "good" : ""}`}>{d.approved ? "Approved" : "Waiting"}</span>
        </div>
      ))}
    </div>
  )
}
