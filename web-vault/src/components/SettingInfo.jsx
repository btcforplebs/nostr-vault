// The (i) after a setting's name (iPhone InfoButton, settingInfo): a tap shows one or two sentences about what it
// does (net/settings-help.js), another tap, Escape or a tap elsewhere puts them away. A topic with no words draws
// nothing. It never toggles the row it sits in. The bubble is fixed to the window under the button (popAt), since the
// Settings cards clip what overflows them.
import { useEffect, useRef, useState } from "preact/hooks"
import { helpTopic } from "../net/settings-help.js"
import { popAt } from "./setting-info.js"

export function SettingInfo({ topic }) {
  const t = helpTopic(topic)
  const [open, setOpen] = useState(null) // the bubble's place while it shows
  const box = useRef(null)
  useEffect(() => {
    if (!open) return
    const away = e => { if (!box.current?.contains(e.target)) setOpen(null) }
    const key = e => { if (e.key === "Escape") setOpen(null) }
    const gone = () => setOpen(null) // a scroll moves the button away from a fixed bubble
    addEventListener("pointerdown", away); addEventListener("keydown", key); addEventListener("scroll", gone, true)
    return () => { removeEventListener("pointerdown", away); removeEventListener("keydown", key); removeEventListener("scroll", gone, true) }
  }, [open])
  if (!t) return null
  return (
    <span class="setting-info" ref={box}>
      <button type="button" class="setting-info-btn" aria-label={`About ${t.title}`} aria-expanded={!!open}
        onClick={e => { e.preventDefault(); e.stopPropagation(); setOpen(open ? null : popAt(e.currentTarget.getBoundingClientRect(), innerWidth)) }}>
        <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="9" /><path d="M12 11v6M12 7.5h.01" /></svg>
      </button>
      {open && <span class="setting-info-pop" role="note" style={{ top: `${open.top}px`, left: `${open.left}px`, width: `${open.width}px` }}><b>{t.title}</b>{t.text}</span>}
    </span>
  )
}
