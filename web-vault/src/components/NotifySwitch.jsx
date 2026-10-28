// Settings › Notifications: the browser notifications switch (net/notify-watch.js). Off until turned on here; turning
// it on is the only place the app asks the browser for permission, so it only ever asks on the user's tap.
import { useEffect, useState } from "preact/hooks"
import { notifyOn, onNotifyPref, permission, setNotifyOn, turnOn } from "../net/notify-watch.js"

const WHY = {
  denied: "This browser blocks notifications for this site. Allow them in the browser's site settings, then turn this on again.",
  unsupported: "This browser can't show notifications from a web page. On iPhone and iPad, add Nostr Vault to the Home Screen first.",
}

export function NotifySwitch() {
  const [on, setOn] = useState(() => notifyOn() && permission() === "granted")
  const [why, setWhy] = useState("")
  useEffect(() => onNotifyPref(() => setOn(notifyOn() && permission() === "granted")), [])
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
      <p class="settings-note muted small">{why || "While Nostr Vault is open in a tab, even in the background, new replies, mentions, likes, zaps and followers show as notifications. Nothing is sent to a push server: the tab asks your relays about once a minute."}</p>
    </>
  )
}
