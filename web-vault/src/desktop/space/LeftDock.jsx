// The left side column (plan NV_WEB_ONE_PLAN.md step 3): cards under the menu, beside the slim rail. Empty by default;
// it shows only at full width (1280px and up) and only when it has cards or the columns are being edited, so the
// layout is today's until someone puts a card here. CardColumn.jsx draws the cards, from the same layout Your space uses.
import { useLayout } from "./layout-store.js"
import { CardColumn, cardsOn } from "./CardColumn.jsx"
import { LEFT } from "./columns.js"
import "../../styles/space.css"

/** Whether the left column draws anything for `me` (DesktopShell sets the layout's width from it). */
export function useLeftShown(me, editing) {
  const [layout] = useLayout(me)
  return editing || cardsOn(layout, LEFT, me).length > 0
}

export function LeftDock({ ctx, editing, onEdit, onAdd }) {
  const [layout, change] = useLayout(ctx.session.pubkey)
  return (
    <aside class={editing ? "left-dock editing" : "left-dock"} aria-label="Left column">
      {editing && (
        <header class="sp-top">
          <h2>Left column</h2>
          <button type="button" class="sp-done" onClick={() => onEdit(false)}>Done</button>
        </header>
      )}
      <div class="sp-panels">
        <CardColumn ctx={ctx} side={LEFT} layout={layout} change={change} editing={editing} onAdd={onAdd} onEdit={() => onEdit(true)} />
      </div>
    </aside>
  )
}
