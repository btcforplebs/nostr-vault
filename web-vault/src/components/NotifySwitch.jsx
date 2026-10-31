// Settings › Notifications: the browser notifications switch (net/notify-watch.js). Off until turned on here; turning
// it on is the only place the app asks the browser for permission, so it only ever asks on the user's tap.
import { useEffect, useState } from "preact/hooks"
import { notifyOn, onNotifyPref, permission, setNotifyOn, turnOn } from "../net/notify-watch.js"
import { TYPES, readTypes, setType, onTypes } from "../net/notify-prefs.js"

const WHY = {
  denied: "This browser blocks notifications for this site. Allow them in the browser's site settings, then turn this on again.",
  unsupported: "This browser can't show notifications from a web page. On iPhone and iPad, add Nostr Vault to the Home Screen first.",
}

export function NotifySwitch() {
  const [on, setOn] = useState(() => notifyOn() && permission() === "granted")
  const [why, setWhy] = useState("")
  const [types, setTypes] = useState(readTypes)
  useEffect(() => onNotifyPref(() => setOn(notifyOn() && permission() === "granted")), [])
  useEffect(() => onTypes(() => setTypes(readTypes())), [])
  const flip = async e => {
    const want = e.currentTarget.checked
    setWhy("")
    if (!want) { setNotifyOn(false); setOn(false); return }
    const p = await turnOn().catch(() => "denied")
    setOn(p === "granted")
    if (p !== "granted") setWhy(WHY[p] ?? "Notifications weren't allowed, so they stay off.")
  }
  return (
    <>
      <label class="settings-row static notify-switch">
        <span class="settings-title">Browser notifications</span>
        <input type="checkbox" role="switch" checked={on} onChange={flip} />
      </label>
      {on && TYPES.map(t => (
        <label key={t.id} class="settings-row static notify-switch notify-type">
          <span class="settings-title">{t.title}</span>
          <input type="checkbox" role="switch" checked={types[t.id]} onChange={e => setType(t.id, e.currentTarget.checked)} />
        </label>
      ))}
      <p class="settings-note muted small">{why || "While Nostr Vault is open in a tab, even in the background, what you pick here shows as notifications. Nothing goes through a push server: the tab asks your relays every minute while you are looking at it, every five minutes while it is in the background, and right away when you come back to it, so nothing arrives once every tab is closed. Messages are opened by your signer as they arrive."}</p>
    </>
  )
}
