// Settings › Feed › Web of Trust › Show "Outside your web" under posts (net/outside-switch.js, default on).
import { useState } from "preact/hooks"
import { showsOutside, setShowsOutside } from "../net/outside-switch.js"

export const outsideNote = on => (on
  ? "Replies, quotes and zaps from outside your web fold under one line you can open, under posts and at the end of feeds."
  : "Nothing from outside your web shows under posts or in feeds. Vault › ··· › Outside still lists it.")

export function OutsideSwitch() {
  const [on, setOn] = useState(() => showsOutside())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Show "Outside your web" under posts</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => { setShowsOutside(e.currentTarget.checked); setOn(showsOutside()) }} />
      </label>
      <p class="settings-note muted small">{outsideNote(on)}</p>
    </>
  )
}
