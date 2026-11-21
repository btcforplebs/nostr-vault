// Settings › Who Can Reach You (iPhone RelayAccessSettingsView): the Web of Trust section's Minimum Followers and
// Refresh Trust List (net/trust-settings.js). The mesh (which vaults may reach this browser's relay) is the Vault
// Dashboard's Mesh settings (#/relay), not this page. Follow Distance isn't on the web yet.
import { useEffect, useState } from "preact/hooks"
import { MIN_FOLLOWERS_RANGE, REFRESH_CHOICES, minFollowers, setMinFollowers, refreshChoice, setRefreshChoice, onTrustSettings } from "../../net/trust-settings.js"
import { SettingInfo } from "../../components/SettingInfo.jsx"
import { Section } from "./Section.jsx"

export const RELAY_ACCESS_NOTE = "Someone is in your web when at least this many of the people you follow follow them. Notes, replies, mentions and messages from outside your web are folded away or held back."

export function RelayAccessPage() {
  const [n, setN] = useState(() => minFollowers())
  const [refresh, setRefresh] = useState(() => refreshChoice())
  useEffect(() => onTrustSettings(() => { setN(minFollowers()); setRefresh(refreshChoice()) }), [])
  const step = d => setN(setMinFollowers(n + d))
  return (
    <Section label="Web of Trust" note={RELAY_ACCESS_NOTE}>
      <div class="settings-row static line-stepper">
        <span class="settings-title">Minimum Followers<SettingInfo topic="relay.minFollowers" /></span>
        <span class="muted line-stepper-value" aria-live="polite">{n}</span>
        <span class="seg-pill" role="group" aria-label="Minimum Followers">
          <button type="button" aria-label="Fewer followers" disabled={n <= MIN_FOLLOWERS_RANGE[0]} onClick={() => step(-1)}>−</button>
          <button type="button" aria-label="More followers" disabled={n >= MIN_FOLLOWERS_RANGE[1]} onClick={() => step(1)}>+</button>
        </span>
      </div>
      <label class="settings-row static">
        <span class="settings-title">Refresh Trust List<SettingInfo topic="relay.wotRefresh" /></span>
        <select class="settings-select" value={refresh} onChange={e => setRefresh(setRefreshChoice(e.currentTarget.value))}>
          {REFRESH_CHOICES.map(c => <option key={c.id} value={c.id}>{c.label}</option>)}
        </select>
      </label>
    </Section>
  )
}
