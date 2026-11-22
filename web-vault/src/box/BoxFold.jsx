// The Box screen's sections, folded into the Vault Dashboard in box mode (One Vault W1, spec §2.3): Status under the
// status card, Mesh and My Devices as Your devices, Storage and Move vault to… in In your vault, Public on the web in
// Vault settings, Update in Advanced. `box`: useBoxDashboard's answer. Each section still loads on its own.
import { StatusSection } from "./sections/StatusSection.jsx"
import { StorageSection } from "./sections/StorageSection.jsx"
import { MeshSection } from "./sections/MeshSection.jsx"
import { DevicesSection } from "./sections/DevicesSection.jsx"
import { PublicSection } from "./sections/PublicSection.jsx"
import { UpdateSection } from "./sections/UpdateSection.jsx"
if (import.meta.env) import("./box.css")

export const BoxStatusDetails = ({ box }) => <div class="box-fold"><StatusSection state={box.data.status} /></div>

export const BoxDevices = ({ box }) => (
  <div class="box-fold"><MeshSection state={box.data.status} /><DevicesSection state={box.data.devices} /></div>
)

export const BoxStorage = ({ box }) => (
  <div class="box-fold"><StorageSection api={box.api} state={box.data.storage} onMoved={() => { box.load("storage"); box.load("contents") }} /></div>
)

export const BoxPublic = ({ ctx, box }) => <div class="box-fold"><PublicSection ctx={ctx} state={box.data.status} /></div>

export const BoxUpdate = ({ box }) => <div class="box-fold"><UpdateSection api={box.api} state={box.data.status} /></div>
