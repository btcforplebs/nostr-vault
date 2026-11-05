// Settings › Privacy (iPhone PrivacySettingsView): the two lookups that send a request signed by your key to a third
// party, with the phone's words. The web makes neither (net/followers.js counts followers from your relays; a locked
// article links out to Fanfares, readers/ArticlesScreen.jsx), so both show off and can't be turned on yet.
import { SettingInfo } from "../../components/SettingInfo.jsx"
import { Section } from "./Section.jsx"

export const WEB_NOTE = "Nostr Vault on the web doesn't make either lookup yet, so both stay off here."

const Row = ({ title, info }) => (
  <label class="settings-row static notify-switch">
    <span class="settings-title">{title}<SettingInfo topic={info} /></span>
    <input type="checkbox" role="switch" checked={false} disabled aria-describedby="privacy-web-note" />
  </label>
)

export function PrivacyPage() {
  return (
    <>
      <Section label="Profiles" note="Off, a profile's follower count comes from your relays, which may count fewer.">
        <Row title="Follower Counts from Vertex" info="privacy.vertex" />
      </Section>
      <Section label="Articles" note="Off, a locked Fanfares article links out to Fanfares, where you open it.">
        <Row title="Check Fanfares Articles" info="privacy.fanfares" />
      </Section>
      <p class="settings-note muted small" id="privacy-web-note">{WEB_NOTE}</p>
    </>
  )
}
