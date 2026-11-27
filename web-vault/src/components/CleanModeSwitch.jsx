// Settings › Muted Words › Clean mode (net/clean-mode.js): mask swear words as f***. Off until turned on, kept on this
// device only, never published.
import { useState } from "preact/hooks"
import { cleanMode, setCleanMode } from "../net/clean-mode.js"

export function CleanModeSwitch() {
  const [on, setOn] = useState(() => cleanMode())
  return (
    <section class="settings-group">
      <div class="section-label">Clean Mode</div>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Mask swear words, like f***</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => setOn(setCleanMode(e.currentTarget.checked))} />
      </label>
      <p class="settings-note muted small">Shows swear words in notes, messages, notifications and names as their first letter and asterisks. Only on this device; what you write and send is never changed.</p>
    </section>
  )
}
