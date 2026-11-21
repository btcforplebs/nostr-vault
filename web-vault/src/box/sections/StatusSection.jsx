// Box screen, Status: how long the box has run, its version, memory and disk. `state`: the status call's { value } | { error }.
import { Part, Row, Meter } from "./Parts.jsx"
import { uptime } from "../format.js"

export function StatusSection({ state }) {
  const status = state?.value
  return (
    <Part title="Status" state={state}>
      {status && <div class="settings-rows">
        <Row label="Running" value={`for ${uptime(status.uptime)}`} />
        <Row label="Version" value={status.version || "—"} />
        <Meter label="Memory" used={status.mem?.used} total={status.mem?.total} />
        <Meter label="Disk" used={status.disk?.used} total={status.disk?.total} />
      </div>}
    </Part>
  )
}
