// Settings › Notifications › Show message text (iPhone PushNotificationSettingsView): off, a message notification
// says who it is from; on, it shows the text too (net/dm-notify.js). Shown while notifications are on, as on the phone.
import { useState } from "preact/hooks"
import { showDmText, setShowDmText } from "../net/dm-notify.js"

export const DM_TEXT_NOTE = "Off: a message notification shows who it is from, not what it says."

export function DmTextSwitch() {
  const [on, setOn] = useState(() => showDmText())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Show message text</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => setOn(setShowDmText(e.currentTarget.checked))} />
      </label>
      <p class="settings-note muted small">{DM_TEXT_NOTE}</p>
    </>
  )
}
