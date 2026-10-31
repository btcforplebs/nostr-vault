// Settings › Post buttons (iPhone AppearanceSettingsView): the zap button under posts, off until turned on here.
import { useState } from "preact/hooks"
import { zapButtonOn, setZapButton } from "../net/post-buttons.js"

export function PostButtonsSwitch() {
  const [on, setOn] = useState(() => zapButtonOn())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Zap button ⚡️</span>
        <input type="checkbox" role="switch" checked={on} onChange={e => { setZapButton(e.currentTarget.checked); setOn(zapButtonOn()) }} />
      </label>
      <p class="settings-note muted small">Shows a zap button on posts. Zaps go straight from your own wallet to the author over Nostr Wallet Connect. Profile zaps are always available.</p>
    </>
  )
}
