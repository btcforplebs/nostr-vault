// One side column's cards (plan NV_WEB_ONE_PLAN.md step 3): Your space on the right (SpaceDock.jsx) and the column
// under the menu on the left (LeftDock.jsx) draw their cards with this, from the one saved layout (columns.js). Our
// panels (panels.js) and installed apps (AppCard.jsx) are cards alike: collapse, and while editing size, move to the
// other column, up, down, take off and drag (within or across the columns).
import { appStore } from "../../napplet/catalog.js"
import { PANELS, PANEL_IDS } from "./panels.js"
import { columnCards, moveInColumn, dropCard, moveAcross, setSize, takeOff, isAppCard, lineOfCard, surfaceOf, appSize, LEFT, SIZES, SIZE_PX } from "./columns.js"
import { setOpen } from "./space-layout.js"
import { CollapseButton, EditTools, useDragPanels } from "./SpaceEdit.jsx"
import { AppCard, appTitle } from "./AppCard.jsx"
import { WidgetCard, isWidget } from "./WidgetCard.jsx"
import { nappletsOn } from "../../napplet/flag.js"

const ADD = "M12 5v14M5 12h14"
export const PANEL_BY_ID = new Map(PANELS.map(p => [p.id, p]))
export const PANEL_NAMES = Object.fromEntries(PANELS.map(p => [p.id, p.name]))

/** What a column can draw: our panels, and the apps this account still has installed. */
export function drawableFor(me) {
  const installed = new Set(appStore(localStorage, me).list().map(a => a.line))
  return id => PANEL_IDS.includes(id) || (isAppCard(id) && installed.has(lineOfCard(id)))
}

/** The cards `side` draws for `me`. */
export const cardsOn = (layout, side, me) => columnCards(layout, side, drawableFor(me))

/** A card's name: ours from panels.js, an app's from its manifest. */
export const cardName = (me, id) => PANEL_BY_ID.get(id)?.name ?? (appTitle(me, id) || "App")

/** canLeft: the left column shows at this width, so "move to the other column" makes sense. */
export function CardColumn({ ctx, side, layout, change, editing, canLeft = true, onAdd, onEdit, footer = null }) {
  const me = ctx.session.pubkey
  const canDraw = drawableFor(me)
  const shown = columnCards(layout, side, canDraw)
  const drag = useDragPanels(shown.map(p => p.id), (id, before) => change(l => dropCard(l, id, side, before)))
  const widgets = nappletsOn()
  const across = side === LEFT ? "Move to Your space" : "Move to the left column"
  return (
    <div class={editing ? "sp-cards editing" : "sp-cards"} {...(editing ? drag.area : {})}>
      {editing && <p class="sp-edit-hint">{side === LEFT
        ? "Cards here sit under the menu. Drag one in from Your space, or add one."
        : "Drag a card or use its arrows to move it, here or to the left column. Pick a size, take off what you don't use."}</p>}
      {shown.map(({ id, open, size }, i) => {
        const app = isAppCard(id)
        const name = cardName(me, id)
        const sizes = app ? surfaceOf(appStore(localStorage, me).get(lineOfCard(id))?.event).sizes : [null, ...SIZES]
        const tools = editing
          ? <EditTools name={name} first={i === 0} last={i === shown.length - 1}
              sizes={sizes} size={app ? appSize(size, sizes) : (size ?? null)} onSize={s => change(l => setSize(l, id, s))}
              across={across} onAcross={canLeft ? () => change(l => moveAcross(l, id)) : null}
              onMove={d => change(l => moveInColumn(l, id, d, canDraw))} onHide={() => change(l => takeOff(l, id))} />
          : <CollapseButton name={name} open={open} onToggle={() => change(l => setOpen(l, id, !open))} />
        const sized = !app && size && open && !editing
        const cls = ["sp-slot", drag.over === id && `drop-${drag.side}`, sized && "sized"].filter(Boolean).join(" ")
        const Panel = PANEL_BY_ID.get(id)?.Panel
        // Napplets on (flag.js): our panels that have a widget draw as one (plan step 4), the rest as today.
        const widget = !app && widgets && isWidget(id)
        return (
          <div key={id} class={cls} style={sized ? { height: `${SIZE_PX[size]}px` } : undefined} {...(editing ? drag.slot(id) : {})}>
            {app ? <AppCard ctx={ctx} id={id} open={open} size={size} editing={editing} tools={tools} onGone={() => change(l => takeOff(l, id))} />
              : widget ? <WidgetCard ctx={ctx} id={id} name={name} open={open} editing={editing} tools={tools} size={size ?? null} side={side} />
              : <Panel ctx={ctx} open={open && !editing} tools={tools} />}
          </div>
        )
      })}
      {!shown.length && !editing && side !== LEFT && (
        <p class="sp-nothing">Nothing here. <button type="button" class="sp-link" onClick={onEdit}>Edit</button> to add cards.</p>
      )}
      {editing && (
        <div class="sp-add">
          <button type="button" class="sp-add-row" onClick={() => onAdd(side)}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d={ADD} /></svg>Add
          </button>
          {footer}
        </div>
      )}
    </div>
  )
}
