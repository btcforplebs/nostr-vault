// "Your space"'s edit pieces (SpaceDock.jsx): a panel's collapse chevron, its buttons while editing (drag handle, up,
// down, take off), the "+ add" list of panels taken off, and the drag-and-drop between panels. They only report what
// was asked; SpaceDock.jsx changes the layout (space-layout.js).
import { useState } from "preact/hooks"
import { Icon, ICON } from "../icons.jsx"

const UP = "M6 15l6-6 6 6", DOWN = ICON.chevron, OFF = "M6 6l12 12M18 6L6 18", ADD = "M12 5v14M5 12h14"
const GRIP = "M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01"

/** Open or collapse a panel to its header. */
export const CollapseButton = ({ name, open, onToggle }) => (
  <button type="button" class={open ? "sp-btn sp-fold" : "sp-btn sp-fold closed"} aria-expanded={open}
    title={open ? `Collapse ${name}` : `Open ${name}`} aria-label={open ? `Collapse ${name}` : `Open ${name}`} onClick={onToggle}>
    <Icon d={ICON.chevron} size={16} />
  </button>
)

/** A panel's buttons while editing. The grip is where a drag starts (the whole panel drags). */
export const EditTools = ({ name, first, last, onMove, onHide }) => (
  <span class="sp-tools">
    <button type="button" class="sp-btn" disabled={first} title={`Move ${name} up`} aria-label={`Move ${name} up`} onClick={() => onMove(-1)}><Icon d={UP} size={16} /></button>
    <button type="button" class="sp-btn" disabled={last} title={`Move ${name} down`} aria-label={`Move ${name} down`} onClick={() => onMove(1)}><Icon d={DOWN} size={16} /></button>
    <button type="button" class="sp-btn sp-off" title={`Take ${name} off Your space`} aria-label={`Take ${name} off Your space`} onClick={onHide}><Icon d={OFF} size={16} /></button>
    <span class="sp-grip" title="Drag to move" aria-hidden="true"><Icon d={GRIP} size={18} /></span>
  </span>
)

/** The panels taken off, to add back, and the way back to the start. */
export const AddPanels = ({ names, onAdd, onReset }) => (
  <div class="sp-add">
    {names.length > 0 && <h4>Add to Your space</h4>}
    {names.map(([id, name]) => (
      <button key={id} type="button" class="sp-add-row" onClick={() => onAdd(id)}><Icon d={ADD} size={16} />{name}</button>
    ))}
    {onReset && <button type="button" class="sp-link sp-reset" onClick={onReset}>Reset to the default</button>}
  </div>
)

/**
 * Drag a panel onto another to move it there: above that panel when dropped on its top half, below it on its bottom
 * half. -> { over, side, slot(id) }: the panel under the pointer and which half, for the drop line, and the props each
 * panel's slot takes. `ids` is the drawn order; `onDrop(id, beforeId)` (beforeId null = at the end).
 */
export function useDragPanels(ids, onDrop) {
  const [drag, setDrag] = useState(null) // { id, over, side }
  const half = e => {
    const r = e.currentTarget.getBoundingClientRect()
    return e.clientY < r.top + r.height / 2 ? "before" : "after"
  }
  const slot = id => ({
    draggable: true,
    onDragStart: e => { e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", id); setDrag({ id, over: null, side: null }) },
    onDragOver: e => {
      if (!drag) return
      e.preventDefault()
      const side = half(e)
      if (drag.over !== id || drag.side !== side) setDrag({ ...drag, over: id, side })
    },
    onDrop: e => {
      e.preventDefault()
      if (!drag) return
      const i = ids.indexOf(id)
      onDrop(drag.id, half(e) === "before" ? id : (ids[i + 1] ?? null))
      setDrag(null)
    },
    onDragEnd: () => setDrag(null),
  })
  return { over: drag?.over !== drag?.id ? drag?.over : null, side: drag?.side, slot }
}
