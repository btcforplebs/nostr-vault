// "Your space" (Logen, 2026-11-02): the right-hand column of the desktop layout, panels pinned beside whatever the
// left column shows. Folded, it is a thin strip that still shows the Vault's unread count. Folded or open is kept per
// account in this browser (live-vault.js readFolded). Editable (Logen, 2026-11-03): each panel collapses to its header
// with its chevron, and Edit lets you drag or move panels up and down, take them off and add them back
// (space-layout.js; layout-store.js keeps it in this browser and in the user's vault; SpaceEdit.jsx draws the edit
// buttons).
import { useState } from "preact/hooks"
import { useVaultUnread } from "../../components/useVaultUnread.js"
import { badgeCount } from "../../components/useUnreadTotal.js"
import { readFolded, writeFolded } from "./live-vault.js"
import { shownPanels, hiddenPanels, setOn, setOpen, moveBy, moveBefore, defaultLayout, sameLayout, resetPanels } from "./space-layout.js"
import { useLayout } from "./layout-store.js"
import { PANELS, PANEL_IDS } from "./panels.js"
import { CollapseButton, EditTools, AddPanels, useDragPanels } from "./SpaceEdit.jsx"
import { Icon, ICON } from "../Sidebar.jsx"
import "../../styles/space.css"

const FOLD = "M9 6l6 6-6 6", OPEN = "M15 6l-6 6 6 6"
const byId = new Map(PANELS.map(p => [p.id, p]))

/** [folded, setFolded] for the signed-in account. */
export function useSpaceFolded(me) {
  const [folded, setFolded] = useState(() => readFolded(me))
  return [folded, v => { setFolded(v); writeFolded(me, v) }]
}

export function SpaceDock({ ctx, folded, onFold }) {
  const unread = useVaultUnread()
  const [layout, change] = useLayout(ctx.session.pubkey)
  const [editing, setEditing] = useState(false)
  const shown = shownPanels(layout, PANEL_IDS)
  const drag = useDragPanels(shown.map(p => p.id), (id, before) => change(l => moveBefore(l, id, before)))
  if (folded) return (
    <aside class="space-dock folded" aria-label="Your space">
      <button type="button" class="sp-btn" title="Show Your space (])" aria-label="Show Your space" onClick={() => onFold(false)}><Icon d={OPEN} size={18} /></button>
      <button type="button" class="sp-mini" title={unread ? `Live Vault: ${unread} new` : "Live Vault"} aria-label={`Live Vault${unread ? `, ${unread} new` : ""}`} onClick={() => onFold(false)}>
        <Icon d={ICON.vault} size={20} />{unread > 0 && <span class="sp-mini-badge">{badgeCount(unread)}</span>}
      </button>
    </aside>
  )
  const isDefault = sameLayout(layout, defaultLayout(PANEL_IDS))
  return (
    <aside class={editing ? "space-dock editing" : "space-dock"} aria-label="Your space">
      <header class="sp-top">
        <h2>Your space</h2>
        {editing
          ? <button type="button" class="sp-done" onClick={() => setEditing(false)}>Done</button>
          : <button type="button" class="sp-btn" title="Edit Your space" aria-label="Edit Your space" onClick={() => setEditing(true)}><Icon d={ICON.post} size={17} /></button>}
        <button type="button" class="sp-btn" title="Fold Your space (])" aria-label="Fold Your space" onClick={() => onFold(true)}><Icon d={FOLD} size={18} /></button>
      </header>
      <div class="sp-panels">
        {editing && <p class="sp-edit-hint">Drag a panel or use its arrows to move it. Take off what you don't use.</p>}
        {shown.map(({ id, open }, i) => {
          const { name, Panel } = byId.get(id)
          const tools = editing
            ? <EditTools name={name} first={i === 0} last={i === shown.length - 1}
                onMove={d => change(l => moveBy(l, id, d, PANEL_IDS))} onHide={() => change(l => setOn(l, id, false))} />
            : <CollapseButton name={name} open={open} onToggle={() => change(l => setOpen(l, id, !open))} />
          return (
            <div key={id} class={drag.over === id ? `sp-slot drop-${drag.side}` : "sp-slot"} {...(editing ? drag.slot(id) : {})}>
              <Panel ctx={ctx} open={open && !editing} tools={tools} />
            </div>
          )
        })}
        {!shown.length && !editing && (
          <p class="sp-nothing">Nothing here. <button type="button" class="sp-link" onClick={() => setEditing(true)}>Edit</button> to add panels.</p>
        )}
        {editing && (
          <AddPanels names={hiddenPanels(layout, PANEL_IDS).map(id => [id, byId.get(id).name])}
            onAdd={id => change(l => setOn(l, id, true))}
            onReset={isDefault ? null : () => change(l => resetPanels(l, PANEL_IDS))} />
        )}
      </div>
    </aside>
  )
}
