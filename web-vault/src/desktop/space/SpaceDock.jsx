// "Your space" (Logen, 2026-11-02): the right-hand column of the desktop layout, panels pinned beside whatever the
// left column shows, in panels.js's order. Folded, it is a thin strip that still shows the
// Vault's unread count. Folded or open is kept per account in this browser (live-vault.js readFolded).
import { useState } from "preact/hooks"
import { useVaultUnread } from "../../components/useVaultUnread.js"
import { badgeCount } from "../../components/useUnreadTotal.js"
import { readFolded, writeFolded } from "./live-vault.js"
import { PANELS } from "./panels.js"
import { Icon, ICON } from "../Sidebar.jsx"
import "../../styles/space.css"

const FOLD = "M9 6l6 6-6 6", OPEN = "M15 6l-6 6 6 6"

/** [folded, setFolded] for the signed-in account. */
export function useSpaceFolded(me) {
  const [folded, setFolded] = useState(() => readFolded(me))
  return [folded, v => { setFolded(v); writeFolded(me, v) }]
}

export function SpaceDock({ ctx, folded, onFold }) {
  const unread = useVaultUnread()
  if (folded) return (
    <aside class="space-dock folded" aria-label="Your space">
      <button type="button" class="sp-btn" title="Show Your space (])" aria-label="Show Your space" onClick={() => onFold(false)}><Icon d={OPEN} size={18} /></button>
      <button type="button" class="sp-mini" title={unread ? `Live Vault: ${unread} new` : "Live Vault"} aria-label={`Live Vault${unread ? `, ${unread} new` : ""}`} onClick={() => onFold(false)}>
        <Icon d={ICON.vault} size={20} />{unread > 0 && <span class="sp-mini-badge">{badgeCount(unread)}</span>}
      </button>
    </aside>
  )
  return (
    <aside class="space-dock" aria-label="Your space">
      <header class="sp-top">
        <h2>Your space</h2>
        <button type="button" class="sp-btn" title="Fold Your space (])" aria-label="Fold Your space" onClick={() => onFold(true)}><Icon d={FOLD} size={18} /></button>
      </header>
      <div class="sp-panels">
        {PANELS.map(({ id, Panel }) => <Panel key={id} ctx={ctx} />)}
      </div>
    </aside>
  )
}
