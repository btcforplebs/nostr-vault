// Edit Feeds, as on the iPhone (Views/Feed/FeedMenuEditor.swift): show, hide and reorder the picker's feeds. Tap a row
// to show or hide it; drag its handle (or focus the handle and press ↑ / ↓) to move it. Following is always shown.
// Every change is saved at once (net/feeds.js saveMenu); FeedScreen switches to Following when the feed you're on is hidden.
import { useEffect, useRef, useState } from "preact/hooks"
import { FEED_ICON, LIST_ICON, Icon } from "./FeedPickerMenu.jsx"
import { PINNED_FEED, menuFeeds, moveItem } from "../net/feeds.js"

if (import.meta.env) import("../styles/edit-feeds.css")

const HANDLE_ICON = "M4 8h16M4 12h16M4 16h16"

/** `feeds`: every feed in its default order. `menu`: { order, hidden }. `onChange(menu)` on every change. */
export function EditFeeds({ feeds, menu, onChange, onClose }) {
  const rows = menuFeeds(feeds, menu)
  const ids = rows.map(r => r.id)
  const isDefault = !menu.hidden.some(id => id !== PINNED_FEED && ids.includes(id)) && ids.every((id, i) => id === feeds[i].id)
  const box = useRef(null), list = useRef(null)
  const [dragging, setDragging] = useState(null)
  const [moved, setMoved] = useState(null) // the handle moved by ↑ / ↓, which keeps focus
  useEffect(() => { box.current?.querySelector(".edit-feeds-done")?.focus() }, [])

  const flip = id => {
    if (id === PINNED_FEED) return
    onChange({ order: ids, hidden: menu.hidden.includes(id) ? menu.hidden.filter(h => h !== id) : [...menu.hidden, id] })
  }
  const move = (from, to) => {
    if (to < 0 || to >= ids.length || to === from) return
    onChange({ order: moveItem(ids, from, to), hidden: menu.hidden })
  }
  // Pointer drag on the handle, for a mouse and a finger alike: the row follows the row under the pointer. The moves are
  // heard on the window, as reordering moves the row's node and a finger's events can stop reaching the handle.
  useEffect(() => {
    if (dragging === null) return
    const over = e => {
      const els = [...(list.current?.children ?? [])]
      const to = els.findIndex(el => { const r = el.getBoundingClientRect(); return e.clientY >= r.top && e.clientY < r.bottom })
      if (to >= 0) move(ids.indexOf(dragging), to)
    }
    const end = () => setDragging(null)
    addEventListener("pointermove", over); addEventListener("pointerup", end); addEventListener("pointercancel", end)
    return () => { removeEventListener("pointermove", over); removeEventListener("pointerup", end); removeEventListener("pointercancel", end) }
  }, [dragging, menu])
  const startDrag = (e, id) => {
    e.preventDefault()
    setMoved(null)
    setDragging(id)
  }
  const keys = (e, i) => {
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return
    e.preventDefault()
    setMoved(ids[i])
    move(i, i + (e.key === "ArrowUp" ? -1 : 1))
  }
  // Keeps focus on the handle that moved (the list may have moved its node), so ↑ / ↓ can be pressed again.
  useEffect(() => { if (moved) list.current?.querySelector(`[data-id="${moved}"]`)?.focus() }, [ids.join()])

  return (
    <div class="edit-feeds-backdrop" onClick={onClose}>
      <div class="edit-feeds" role="dialog" aria-modal="true" aria-labelledby="edit-feeds-title" ref={box}
        onClick={e => e.stopPropagation()} onKeyDown={e => { if (e.key === "Escape") onClose() }}>
        <div class="edit-feeds-head">
          <span />
          <strong id="edit-feeds-title">Edit Feeds</strong>
          <button type="button" class="edit-feeds-done" onClick={onClose}>Done</button>
        </div>
        <ul class="edit-feeds-list" ref={list}>
          {rows.map((f, i) => {
            const pinned = f.id === PINNED_FEED
            return (
              <li key={f.id} class={`${f.shown ? "shown" : ""}${dragging === f.id ? " dragging" : ""}`}>
                <button type="button" class="edit-feeds-row" role="switch" aria-checked={f.shown} aria-disabled={pinned}
                  aria-label={f.label} title={pinned ? "Always shown" : f.shown ? "Hide this feed" : "Show this feed"}
                  onClick={() => flip(f.id)}>
                  <span class={`edit-feeds-check${pinned ? " pinned" : ""}`} aria-hidden="true">{f.shown ? "✓" : ""}</span>
                  <span class="edit-feeds-icon"><Icon d={FEED_ICON[f.id] ?? LIST_ICON} size={17} /></span>
                  <span class="edit-feeds-name">{f.label}</span>
                </button>
                <button type="button" class="edit-feeds-handle" aria-label={`Move ${f.label}`} title="Drag, or press ↑ / ↓"
                  data-id={f.id}
                  onPointerDown={e => startDrag(e, f.id)} onKeyDown={e => keys(e, i)}>
                  <Icon d={HANDLE_ICON} size={17} />
                </button>
              </li>
            )
          })}
        </ul>
        <p class="edit-feeds-foot">Tap a feed to show or hide it. Drag to change the order. Following is always shown.</p>
        <button type="button" class="edit-feeds-reset" disabled={isDefault} onClick={() => onChange({ order: [], hidden: [] })}>
          Reset to Default
        </button>
      </div>
    </div>
  )
}
