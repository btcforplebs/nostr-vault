// Settings › Posts (iPhone AppearanceSettingsView): hide the Nostr Vault logo beside names on posts. Off until turned on.
import { useState } from "preact/hooks"
import { nvLogoHidden, setNvLogoHidden } from "../net/nv-logo.js"

export function NostrVaultLogoSwitch() {
  const [hidden, setHidden] = useState(() => nvLogoHidden())
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Hide Nostr Vault logo on posts</span>
        <input type="checkbox" role="switch" checked={hidden} onChange={e => { setNvLogoHidden(e.currentTarget.checked); setHidden(nvLogoHidden()) }} />
      </label>
      <p class="settings-note muted small">Posts sent from Nostr Vault show a small vault logo beside the author's name. On, the logo is hidden.</p>
    </>
  )
}
