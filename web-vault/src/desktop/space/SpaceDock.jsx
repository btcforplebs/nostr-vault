// "Your space" (Logen, 2026-11-02): the right-hand column of the desktop layout, panels pinned beside whatever the
// left column shows. A thin icon rail on its right edge is always showing, folded or not (Logen, 2026-11-04, as the
// iPad's SpaceColumn.swift): the dashboard (every panel together) on top, then one icon per panel, which opens just
// that panel, full height. A click on the open one folds the column; any click while folded opens it. Live Vault's
// unread count rides its icon. Folded or open is kept per account in this browser (live-vault.js readFolded). Editable
// (Logen, 2026-11-03; both side columns since plan NV_WEB_ONE_PLAN.md step 3): Edit here edits this column and the
// left one together, CardColumn.jsx draws the cards (ours and installed apps), columns.js holds the rules and
// layout-store.js keeps the layout in this browser, per account.
import { useState } from "preact/hooks"
import { useVaultUnread } from "../../components/useVaultUnread.js"
import { badgeCount } from "../../components/useUnreadTotal.js"
import { readFolded, writeFolded } from "./live-vault.js"
import { RIGHT, isAppCard, resetColumns, isDefaultColumns } from "./columns.js"
import { useLayout } from "./layout-store.js"
import { PANEL_IDS } from "./panels.js"
import { CardColumn, PANEL_BY_ID, cardsOn, cardName } from "./CardColumn.jsx"
import { AppCard } from "./AppCard.jsx"
import { Icon, ICON } from "../Sidebar.jsx"
import { WOT_GLOBE } from "../../components/wot-glyph.js"
import "../../styles/space.css"

const FOLD = "M9 6l6 6-6 6"
const APP_ICON = "M4 4h16v16H4zM4 9h16"
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

/** editing / onEdit(on): both columns are edited together (DesktopShell.jsx); onAdd(side): + Add's sheet. canLeft: the
 *  left column shows at this width. */
export function SpaceDock({ ctx, folded, onFold, editing, onEdit, onAdd, canLeft }) {
  const me = ctx.session.pubkey
  const unread = useVaultUnread()
  const [layout, change] = useLayout(me)
  // The card the rail opened on its own, or null for the dashboard.
  const [only, setOnly] = useState(null)
  const shown = cardsOn(layout, RIGHT, me)
  // A card taken off the layout (here or in the other column) closes if it was open alone.
  const single = only && shown.some(p => p.id === only) ? only : null
  const tap = id => {
    if (folded) { setOnly(id); onFold(false) }
    else if (single === id) onFold(true)
    else { setOnly(id); onEdit(false) }
  }
  const rail = (
    <nav class="sp-rail" aria-label="Your space widgets">
      <RailButton d={DASHBOARD} title="Your space" open={!folded && !single} onClick={() => tap(null)} />
      <span class="sp-rail-rule" aria-hidden="true" />
      {shown.map(({ id }) => (
        <RailButton key={id} d={RAIL_ICON[id] ?? APP_ICON} title={cardName(me, id)} open={!folded && single === id}
          badge={id === "live-vault" ? unread : 0} onClick={() => tap(id)} />
      ))}
    </nav>
  )
  if (folded) return <aside class="space-dock folded" aria-label="Your space">{rail}</aside>
  const isDefault = isDefaultColumns(layout, PANEL_IDS)
  const Only = single && !isAppCard(single) && PANEL_BY_ID.get(single)
  const onlyName = single && cardName(me, single)
  return (
    <aside class={editing ? "space-dock editing" : "space-dock"} aria-label="Your space">
      <div class="sp-main">
        <header class="sp-top">
          <h2>{single ? onlyName : "Your space"}</h2>
          {!single && (editing
            ? <button type="button" class="sp-done" onClick={() => onEdit(false)}>Done</button>
            : <button type="button" class="sp-btn" title={canLeft ? "Edit the side columns" : "Edit Your space"} aria-label={canLeft ? "Edit the side columns" : "Edit Your space"} onClick={() => onEdit(true)}><Icon d={ICON.post} size={17} /></button>)}
          <button type="button" class="sp-btn" title="Fold Your space (])" aria-label="Fold Your space" onClick={() => onFold(true)}><Icon d={FOLD} size={18} /></button>
        </header>
        <div class={single ? "sp-panels sp-only" : "sp-panels"}>
          {Only ? <Only.Panel ctx={ctx} open tools={null} />
            : single ? <AppCard ctx={ctx} id={single} open size="L" editing={false} tools={null} />
            : <CardColumn ctx={ctx} side={RIGHT} layout={layout} change={change} editing={editing} canLeft={canLeft} onAdd={onAdd} onEdit={() => onEdit(true)}
                footer={isDefault ? null : <button type="button" class="sp-link sp-reset" onClick={() => change(l => resetColumns(l, PANEL_IDS))}>Reset both columns to the default</button>} />}
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

