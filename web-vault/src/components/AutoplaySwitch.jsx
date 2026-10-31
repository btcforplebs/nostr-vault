// Settings › Media › Autoplay Videos (iPhone MediaSettingsView's Playback toggle, on by default). Off, a feed video
// waits for its play control (components/MediaParts.jsx InlineVideo).
import { useState } from "preact/hooks"
import { autoplayOn, setAutoplay } from "../net/media-prefs.js"

export function AutoplaySwitch() {
  const [on, setOn] = useState(() => autoplayOn())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Autoplay Videos</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => { setAutoplay(e.currentTarget.checked); setOn(autoplayOn()) }} />
      </label>
      <p class="settings-note muted small">{on ? "Plays videos automatically as you scroll." : "Videos wait for you to tap play."}</p>
    </>
  )
}
