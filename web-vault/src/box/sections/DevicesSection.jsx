// Box screen, My Devices: this box's own address, the owner's devices, Add a device (PairDeviceSection.jsx) and Remove.
// `state`: the devices call's { value } | { error }. `api`: a boxApi, for pairing and Remove; without one the list is
// read-only. `onChanged`: reload the devices after a pairing or a Remove.
import { useState } from "preact/hooks"
import { Part, Row } from "./Parts.jsx"
import { PairDeviceSection } from "./PairDeviceSection.jsx"
import { ago, shortNpub } from "../format.js"

const ROLE = { mac: "Desktop vault · full history", phone: "Phone", homeVault: "Mobile vault · new posts", browser: "Browser vault" }

export function DevicesSection({ state, api, onChanged }) {
  const devices = state?.value
  return (
    <Part title="My Devices" state={state}>
      {devices && <Devices devices={devices} api={api} onChanged={onChanged} />}
    </Part>
  )
}

function Devices({ devices, api, onChanged }) {
  const box = devices.box ?? {}
  const list = Array.isArray(devices.devices) ? devices.devices : []
  const paired = devices.paired === true
  const [removing, setRemoving] = useState(null)
  const [error, setError] = useState(null)
  const remove = async d => {
    const name = d.name?.trim() || ROLE[d.role] || shortNpub(d.npub)
    if (!confirm(`Remove ${name} from this box? It loses access at once and has to pair again.`)) return
    setRemoving(d.npub); setError(null)
    try { await api.removeDevice(d.npub); onChanged?.() } catch (e) { setError(String(e?.message ?? e)) }
    setRemoving(null)
  }
  return (
    <div class="settings-rows">
      <Row label="This box" value={shortNpub(box.npub)} copy={box.npub} />
      {paired
        ? <p class="muted small box-pad">Devices you pair here reach the box over the mesh and the box keeps a copy of your vault from them. Remove one and it loses access at once. The box has no key of yours; it only stores and passes on what you sign.</p>
        : <p class="muted small box-pad">To approve it, open My Devices on your phone or Mac and add this box as a Desktop Vault (Desktop vault · full history). The box has no key of yours; it only stores and passes on what you sign.</p>}
      {list.length === 0 && <p class="muted small box-pad">{paired ? "No devices paired yet." : "No devices of yours have reached the box yet."}</p>}
      {list.map(d => (
        <div key={d.npub} class="settings-row box-row">
          <span class="settings-title">{d.name?.trim() || ROLE[d.role] || "Device"}<span class="muted small box-sub">{[d.name?.trim() && ROLE[d.role], Number.isFinite(d.lastSeen) && `seen ${ago(d.lastSeen)}`, Number.isFinite(d.pairedAt) && d.pairedAt > 0 && `paired ${ago(d.pairedAt)}`].filter(Boolean).join(" · ")}</span></span>
          <span class={`box-value ${d.approved ? "good" : ""}`}>{d.approved ? "Approved" : "Waiting"}</span>
          {paired && api && <button type="button" class="small" disabled={removing === d.npub} onClick={() => remove(d)}>{removing === d.npub ? "Removing…" : "Remove"}</button>}
        </div>
      ))}
      {error && <p class="error small box-pad" role="alert">{error}</p>}
      {api && <PairDeviceSection api={api} onPaired={onChanged} />}
    </div>
  )
}
