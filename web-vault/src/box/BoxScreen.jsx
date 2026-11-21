// The box screens (#/box), as the Mac app's: Status, Storage (Move vault to…), Mesh, My Devices, Public on the web and Update, read from the
// box's owner-only API (api.js). Shown only in box mode (mode.js). Each part loads on its own, so a slow or refused
// call leaves the others showing; an unknown number reads "—", never 0. Each part is its own file in sections/.
import { useEffect, useMemo, useState } from "preact/hooks"
import { boxApi } from "./api.js"
import { StatusSection } from "./sections/StatusSection.jsx"
import { StorageSection } from "./sections/StorageSection.jsx"
import { MeshSection } from "./sections/MeshSection.jsx"
import { DevicesSection } from "./sections/DevicesSection.jsx"
import { PublicSection } from "./sections/PublicSection.jsx"
import { UpdateSection } from "./sections/UpdateSection.jsx"
if (import.meta.env) import("./box.css")

/** `api`: a boxApi; built from the signer when not given (tests and the harness pass one over a mock). */
export function BoxScreen({ ctx, api: given }) {
  const api = useMemo(() => given ?? boxApi({ signer: ctx.signer }), [given, ctx.signer])
  const [data, setData] = useState({}) // part -> { value } | { error }
  const load = part => api[part]().then(value => setData(d => ({ ...d, [part]: { value } })), e => setData(d => ({ ...d, [part]: { error: String(e?.message ?? e) } })))
  useEffect(() => { for (const p of ["status", "storage", "devices"]) load(p) }, [api])
  return (
    <div class="screen box-screen">
      <header class="screen-head"><a class="button small" href="#/settings">‹ Settings</a><h2>Box</h2><span style="width: 92px" /></header>
      <StatusSection state={data.status} />
      <StorageSection api={api} state={data.storage} onMoved={() => load("storage")} />
      <MeshSection state={data.status} />
      <DevicesSection state={data.devices} />
      <PublicSection ctx={ctx} state={data.status} />
      <UpdateSection api={api} state={data.status} />
    </div>
  )
}
