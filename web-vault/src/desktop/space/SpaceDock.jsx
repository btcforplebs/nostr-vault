// "Your space" (Logen, 2026-11-02): the right-hand column of the desktop layout, panels pinned beside whatever the
// left column shows. A thin icon rail on its right edge is always showing, folded or not (Logen, 2026-11-04, as the
// iPad's SpaceColumn.swift): the dashboard (every panel together) on top, then one icon per panel, which opens just
// that panel, full height. A click on the open one folds the column; any click while folded opens it. Live Vault's
// unread count rides its icon. Folded or open is kept per
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
import { WOT_GLOBE } from "../../components/wot-glyph.js"
import "../../styles/space.css"

const FOLD = "M9 6l6 6-6 6"
const byId = new Map(PANELS.map(p => [p.id, p]))
/** The rail's icons: the dashboard, then each panel's own (the glyphs their headers draw). */
const DASHBOARD = "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z"
const RAIL_ICON = {
  "live-vault": ICON.vault,
  "wot-mini": WOT_GLOBE,
  messages: ICON.messages,
  "my-devices": "M3 6a2 2 0 0 1 2-2h11a2 2 0 0 1 2 2v7H3zM1 17h12M18 9h3a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1z",
  "live-now": "M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6zM6.3 6.3a8 8 0 0 0 0 11.4M17.7 6.3a8 8 0 0 1 0 11.4",
  "on-this-day": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2",
}

/** [folded, setFolded] for the signed-in account. */
export function useSpaceFolded(me) {
  const [folded, setFolded] = useState(() => readFolded(me))
  return [folded, v => { setFolded(v); writeFolded(me, v) }]
}

export function SpaceDock({ ctx, folded, onFold }) {
  const unread = useVaultUnread()
  const [layout, change] = useLayout(ctx.session.pubkey)
  const [editing, setEditing] = useState(false)
  // The panel the rail opened on its own, or null for the dashboard.
  const [only, setOnly] = useState(null)
  const shown = shownPanels(layout, PANEL_IDS)
  const drag = useDragPanels(shown.map(p => p.id), (id, before) => change(l => moveBefore(l, id, before)))
  // A panel taken off the layout (here or on the iPad) closes if it was open alone.
  const single = only && shown.some(p => p.id === only) ? only : null
  const tap = id => {
    if (folded) { setOnly(id); onFold(false) }
    else if (single === id) onFold(true)
    else { setOnly(id); setEditing(false) }
  }
  const rail = (
    <nav class="sp-rail" aria-label="Your space widgets">
      <RailButton d={DASHBOARD} title="Your space" open={!folded && !single} onClick={() => tap(null)} />
      <span class="sp-rail-rule" aria-hidden="true" />
      {shown.map(({ id }) => (
        <RailButton key={id} d={RAIL_ICON[id] ?? DASHBOARD} title={byId.get(id).name} open={!folded && single === id}
          badge={id === "live-vault" ? unread : 0} onClick={() => tap(id)} />
      ))}
    </nav>
  )
  if (folded) return <aside class="space-dock folded" aria-label="Your space">{rail}</aside>
  const isDefault = sameLayout(layout, defaultLayout(PANEL_IDS))
  const Only = single && byId.get(single)
  return (
    <aside class={editing ? "space-dock editing" : "space-dock"} aria-label="Your space">
      <div class="sp-main">
        <header class="sp-top">
          <h2>{Only ? Only.name : "Your space"}</h2>
          {!Only && (editing
            ? <button type="button" class="sp-done" onClick={() => setEditing(false)}>Done</button>
            : <button type="button" class="sp-btn" title="Edit Your space" aria-label="Edit Your space" onClick={() => setEditing(true)}><Icon d={ICON.post} size={17} /></button>)}
          <button type="button" class="sp-btn" title="Fold Your space (])" aria-label="Fold Your space" onClick={() => onFold(true)}><Icon d={FOLD} size={18} /></button>
        </header>
        <div class={Only ? "sp-panels sp-only" : "sp-panels"}>
          {Only ? <Only.Panel ctx={ctx} open tools={null} /> : <>
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
          </>}
        </div>
      </div>
      {rail}
    </aside>
  )
}

/** One rail icon; the open one is lit. A count, when there is one, sits on its corner. */
function RailButton({ d, title, open, badge = 0, onClick }) {
  return (
    <button type="button" class={open ? "sp-rail-btn open" : "sp-rail-btn"} title={title} aria-pressed={open}
      aria-label={badge > 0 ? `${title}, ${badge} new` : title} onClick={onClick}>
      <Icon d={d} size={19} />{badge > 0 && <span class="sp-mini-badge">{badgeCount(badge)}</span>}
    </button>
  )
}
