// The side columns' edit pieces (CardColumn.jsx): a card's collapse chevron, its buttons while editing (size, other
// column, up, down, take off, drag handle), and the drag-and-drop between cards and across the two columns. They only
// report what was asked; CardColumn.jsx changes the layout (columns.js).
import { useState } from "preact/hooks"
import { Icon, ICON } from "../icons.jsx"

const UP = "M6 15l6-6 6 6", DOWN = ICON.chevron, OFF = "M6 6l12 12M18 6L6 18", ADD = "M12 5v14M5 12h14"
const ACROSS = "M7 7h13l-4-4M17 17H4l4 4"
const SIZE_WORD = { S: "Small", M: "Medium", L: "Large" }
const GRIP = "M9 6h.01M15 6h.01M9 12h.01M15 12h.01M9 18h.01M15 18h.01"

/** Open or collapse a panel to its header. */
export const CollapseButton = ({ name, open, onToggle }) => (
  <button type="button" class={open ? "sp-btn sp-fold" : "sp-btn sp-fold closed"} aria-expanded={open}
    title={open ? `Collapse ${name}` : `Open ${name}`} aria-label={open ? `Collapse ${name}` : `Open ${name}`} onClick={onToggle}>
    <Icon d={ICON.chevron} size={16} />
  </button>
)

/** A card's buttons while editing. The grip is where a drag starts (the whole card drags). `sizes`: the sizes it can
 *  take (null = its own height, ours only); `across`: the label of the button that moves it to the other column. */
export const EditTools = ({ name, first, last, onMove, onHide, sizes = null, size = null, onSize, across, onAcross }) => (
  <span class="sp-tools">
    {sizes && (
      <span class="sp-sizes" role="radiogroup" aria-label={`Size of ${name}`}>
        {sizes.map(s => (
          <button key={s ?? "fit"} type="button" role="radio" aria-checked={size === s} class={size === s ? "sp-size on" : "sp-size"}
            title={s ? `${SIZE_WORD[s]} (${name})` : `Its own height (${name})`} onClick={() => onSize(s)}>{s ?? "Fit"}</button>
        ))}
      </span>
    )}
    {onAcross && <button type="button" class="sp-btn" title={`${across}: ${name}`} aria-label={`${across}: ${name}`} onClick={onAcross}><Icon d={ACROSS} size={16} /></button>}
    <button type="button" class="sp-btn" disabled={first} title={`Move ${name} up`} aria-label={`Move ${name} up`} onClick={() => onMove(-1)}><Icon d={UP} size={16} /></button>
    <button type="button" class="sp-btn" disabled={last} title={`Move ${name} down`} aria-label={`Move ${name} down`} onClick={() => onMove(1)}><Icon d={DOWN} size={16} /></button>
    <button type="button" class="sp-btn sp-off" title={`Take ${name} off`} aria-label={`Take ${name} off`} onClick={onHide}><Icon d={OFF} size={16} /></button>
    <span class="sp-grip" title="Drag to move" aria-hidden="true"><Icon d={GRIP} size={18} /></span>
  </span>
)

// The card being dragged, shared by both columns so a card dropped in the other column lands there.
let dragging = null

/**
 * Drag a card onto another to move it there: above that card when dropped on its top half, below it on its bottom half;
 * onto a column's empty space, to that column's end. Works across the two columns. -> { over, side, slot(id), area }:
 * the card under the pointer and which half (for the drop line), the props each card's slot takes, and the props of
 * the column's list. `ids` is this column's drawn order; `onDrop(id, beforeId)` (beforeId null = at the end).
 */
export function useDragPanels(ids, onDrop) {
  const [hover, setHover] = useState(null) // { over, side }
  const half = e => {
    const r = e.currentTarget.getBoundingClientRect()
    return e.clientY < r.top + r.height / 2 ? "before" : "after"
  }
  const end = () => { dragging = null; setHover(null) }
  const slot = id => ({
    draggable: true,
    onDragStart: e => { e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", id); dragging = id },
    onDragOver: e => {
      if (!dragging) return
      e.preventDefault()
      e.stopPropagation()
      const side = half(e)
      if (hover?.over !== id || hover?.side !== side) setHover({ over: id, side })
    },
    onDrop: e => {
      e.preventDefault()
      e.stopPropagation()
      if (!dragging) return
      const i = ids.indexOf(id)
      const moving = dragging
      end()
      onDrop(moving, half(e) === "before" ? id : (ids[i + 1] ?? null))
    },
    onDragEnd: end,
  })
  const area = {
    onDragOver: e => { if (dragging) { e.preventDefault(); if (hover) setHover(null) } },
    onDrop: e => { if (!dragging) return; e.preventDefault(); const moving = dragging; end(); onDrop(moving, null) },
  }
  return { over: hover?.over !== dragging ? hover?.over : null, side: hover?.side, slot, area }
}
