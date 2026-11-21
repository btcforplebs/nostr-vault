// Settings › Feed (iPhone FeedSettingsView): where the feed reads from (Feed Relays, Settings › Relays) and Posting's
// Send Delay, What You See (Show Reposts, Show Replies, Auto-Load New Posts) and Troubleshooting's Reload Feed, with the
// phone's words.
import { SendDelayPicker } from "../../components/SendDelayPicker.jsx"
import { SettingInfo } from "../../components/SettingInfo.jsx"
import { Section } from "./Section.jsx"
import { FeedReachSection } from "./FeedReachSection.jsx"
import { OutsideSwitch } from "../../components/OutsideSwitch.jsx"
import { FeedFilterSwitches } from "../../components/FeedFilterSwitches.jsx"
import { askFeedReload } from "../../net/feed-reload.js"

const Chevron = () => <svg class="settings-chevron" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6" /></svg>

export const FEED_RELAYS_NOTE = "Your feed reads from the relays marked Read."
// The Settings napplet's Feed page (napplet/SettingsPane.jsx) has no switches; this points to where they are.
export const FEED_NOTE = "Reposts, Replies and Auto-load are also switched from the Feed's own menu."
export const RELOAD_NOTE = "Loads your feed again from its relays."

export function FeedSettingsPage() {
  return (
    <>
      <Section label="Feed Relays" note={FEED_RELAYS_NOTE}>
        <a class="settings-row" href="#/settings/relays">
          <span class="settings-title">Feed Relays<SettingInfo topic="feed.relays" /></span>
          <Chevron />
        </a>
      </Section>
      <Section label="What You See"><FeedFilterSwitches /></Section>
      <FeedReachSection />
      <Section label="Web of Trust"><OutsideSwitch /></Section>
      <Section label="Posting"><SendDelayPicker /></Section>
      <Section label="Troubleshooting" note={RELOAD_NOTE}>
        <button type="button" class="settings-row reload-feed" onClick={() => askFeedReload()}>
          <span class="settings-title">Reload Feed</span>
        </button>
      </Section>
    </>
  )
}
