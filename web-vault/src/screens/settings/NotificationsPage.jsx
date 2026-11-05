// Settings › Notifications (iPhone PushNotificationSettingsView): the switch, then which alerts this account gets, in
// the phone's names (net/notify-prefs.js). Made by this tab, never a push server (components/NotifySwitch.jsx).
import { NotifySwitch } from "../../components/NotifySwitch.jsx"

export function NotificationsPage() {
  return <section class="settings-group"><div class="settings-rows"><NotifySwitch /></div></section>
}
