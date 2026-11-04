// "Your space"'s panels, in their default order top to bottom (SpaceDock.jsx draws them in the user's order,
// space-layout.js). A new panel is its own file in this folder and one line here: { id, name, Panel }, Panel taking
// { ctx, open, tools }: drawn collapsed to its header when `open` is false, with `tools` (SpaceDock's buttons) at the end
// of that header. The ids are shared with the iPad, so never rename one.
import { LiveVault } from "./LiveVault.jsx"
import { WotMini } from "./WotMini.jsx"
import { MessagesPeek } from "./MessagesPeek.jsx"

export const PANELS = [
  { id: "live-vault", name: "Live Vault", Panel: LiveVault },
  { id: "wot-mini", name: "Web of Trust", Panel: WotMini },
  { id: "messages", name: "Messages", Panel: MessagesPeek },
]
export { PANEL_IDS } from "./panel-ids.js"
