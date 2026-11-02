// "Your space"'s panels, top to bottom (SpaceDock.jsx draws them in this order). A new panel is its own file in this
// folder and one line here: { id, Panel }, Panel taking { ctx }.
import { LiveVault } from "./LiveVault.jsx"
import { WotMini } from "./WotMini.jsx"
import { MessagesPeek } from "./MessagesPeek.jsx"

export const PANELS = [
  { id: "live-vault", Panel: LiveVault },
  { id: "wot-mini", Panel: WotMini },
  { id: "messages", Panel: MessagesPeek },
]
