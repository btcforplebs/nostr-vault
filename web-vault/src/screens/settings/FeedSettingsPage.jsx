// Settings › Feed (iPhone FeedSettingsView): where the feed reads from (Feed Relays, Settings › Relays) and Posting's
// Send Delay, with the phone's words. Its What You See switches aren't on the web: new posts load on their own here,
// and the web feed always shows reposts and replies.
import { SendDelayPicker } from "../../components/SendDelayPicker.jsx"
import { SettingInfo } from "../../components/SettingInfo.jsx"
import { Section } from "./Section.jsx"

const Chevron = () => <svg class="settings-chevron" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>

export function FeedSettingsPage() {
  return (
    <>
      <Section label="Feed Relays" note="Your feed reads from the relays marked Read.">
        <a class="settings-row" href="#/settings/relays">
          <span class="settings-title">Feed Relays<SettingInfo topic="feed.relays" /></span>
          <Chevron />
        </a>
      </Section>
      <Section label="Posting"><SendDelayPicker /></Section>
      <p class="settings-note muted small">New posts load on their own. Reposts and replies always show in your feed on the web.</p>
    </>
  )
}
