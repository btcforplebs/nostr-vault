// Box screen, Mesh: whether the box's mesh is up, its peers and mesh address. `state`: the status call's { value } | { error }.
import { Part, Row } from "./Parts.jsx"
import { shortNpub } from "../format.js"

export function MeshSection({ state }) {
  const status = state?.value
  return (
    <Part title="Mesh" state={state}>
      {status && <div class="settings-rows">
        <Row label="Mesh" value={status.mesh?.up === true ? "Connected" : status.mesh?.up === false ? "Not connected" : "—"} tone={status.mesh?.up ? "good" : ""} />
        <Row label="Peers" value={Number.isFinite(status.mesh?.peers) ? String(status.mesh.peers) : "—"} />
        <Row label="Mesh address" value={shortNpub(status.mesh?.npub)} copy={status.mesh?.npub} />
      </div>}
    </Part>
  )
}
