// List column, divider, note column (iPad NoteSplitPane, design §1). The divider drags between 280px and the window
// less 360px, resets on double-click, and carries a fold tab; width and fold are kept in this browser. At 760–1023px
// there is one column: an open note covers the list, with Back.
import { useEffect, useRef, useState } from "preact/hooks"

export const LIST_DEFAULT = 380
const LIST_MIN = 280, NOTE_MIN = 360
const KEY_WIDTH = "nv.desk.listWidth"

export const clampWidth = (w, total) => Math.round(Math.max(LIST_MIN, Math.min(w, Math.max(LIST_MIN, total - NOTE_MIN))))
/** Until the divider is dragged, the list grows with the window: the iPad's 380px up to ~1400px, 520px by 1920px. */
export const autoWidth = windowWidth => Math.round(Math.max(LIST_DEFAULT, Math.min(520, windowWidth * 0.27)))

export function SplitPane({ single, list, detail, placeholder, noteHidden, setNoteHidden, onBack }) {
  const stored = () => Number(localStorage.getItem(KEY_WIDTH)) || null
  const [width, setWidth] = useState(() => stored() ?? autoWidth(innerWidth))
  const box = useRef()
  const save = w => { setWidth(w); localStorage.setItem(KEY_WIDTH, String(w)) }
  const reset = () => { localStorage.removeItem(KEY_WIDTH); setWidth(autoWidth(innerWidth)) }
  const total = () => box.current?.getBoundingClientRect().width ?? innerWidth

  const drag = e => {
    if (e.button !== 0 || e.target.closest("button")) return
    e.preventDefault()
    const el = e.currentTarget, left = box.current.getBoundingClientRect().left
    el.setPointerCapture(e.pointerId)
    el.classList.add("dragging")
    const move = ev => setWidth(clampWidth(ev.clientX - left, total()))
    const up = ev => {
      el.removeEventListener("pointermove", move); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up)
      el.classList.remove("dragging")
      save(clampWidth(ev.clientX - left, total()))
    }
    el.addEventListener("pointermove", move); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up)
  }
  const nudge = e => {
    const step = e.shiftKey ? 64 : 16
    if (e.key === "ArrowLeft") { e.preventDefault(); save(clampWidth(width - step, total())) }
    if (e.key === "ArrowRight") { e.preventDefault(); save(clampWidth(width + step, total())) }
  }
  // A window made narrower must not leave the note column under its minimum.
  useEffect(() => {
    const fit = () => setWidth(clampWidth(stored() ?? autoWidth(innerWidth), total()))
    addEventListener("resize", fit)
    return () => removeEventListener("resize", fit)
  }, [])

  if (single) {
    return (
      <div class="desk-split single" ref={box}>
        <div class="desk-list" hidden={!!detail}>{list}</div>
        {detail && (
          <div class="desk-detail slide">
            <div class="desk-back"><button type="button" class="small" onClick={onBack}>‹ Back</button></div>
            {detail}
          </div>
        )}
      </div>
    )
  }
  const folded = noteHidden
  return (
    <div class={folded ? "desk-split folded" : "desk-split"} ref={box} style={{ "--list-w": `${clampWidth(width, total())}px` }}>
      <div class="desk-list">{list}</div>
      <div class="desk-divider" role="separator" aria-orientation="vertical" aria-label="Resize the list" tabIndex={0}
        aria-valuenow={width} aria-valuemin={LIST_MIN} title="Drag to resize · double-click to reset"
        onPointerDown={drag} onDblClick={e => { if (!e.target.closest("button")) reset() }} onKeyDown={nudge}>
        <button type="button" class="desk-fold" aria-label={folded ? "Show the note column (])" : "Fold the note column (])"} title={folded ? "Show the note column (])" : "Fold the note column (])"}
          aria-expanded={!folded} onClick={() => setNoteHidden(!folded)}>
          <svg viewBox="0 0 12 24" width="8" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d={folded ? "M8 6l-5 6 5 6" : "M4 6l5 6-5 6"} /></svg>
        </button>
      </div>
      <div class="desk-detail" hidden={folded}>{detail ?? <EmptyDetail text={placeholder} />}</div>
    </div>
  )
}

/** The note column with nothing open: the app mark, and what to pick. */
function EmptyDetail({ text }) {
  return (
    <div class="desk-empty">
      <svg viewBox="0 0 24 24" width="40" height="40" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M5 4h14a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1zM12 13.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 11v2M4 9h3M4 15h3" />
      </svg>
      <p>{text}</p>
    </div>
  )
}
