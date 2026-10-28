// "Vault settings" (VaultDashboardView settingsSection): Relays, Who Can Reach You and Media Servers with their
// values. Sync with Vault on Mac and Start automatically are left out: a browser can't do either (the relay runs
// while the tab is open).
import { Section, SettingRow } from "./parts.jsx"
import { WEB_HOPS } from "./ReachSection.jsx"

export function SettingsSection({ relays, mediaServers }) {
  return (
    <Section title="Vault settings">
      <SettingRow icon="antenna" title="Relays" value={relays != null ? String(relays) : null} href="#/settings/relays" />
      <SettingRow icon="shield" title="Who Can Reach You" value={`${WEB_HOPS} hops`} href="#/relay" />
      <SettingRow icon="server" title="Media Servers" value={mediaServers != null ? String(mediaServers) : null} href="#/settings/media-servers" />
    </Section>
  )
}
