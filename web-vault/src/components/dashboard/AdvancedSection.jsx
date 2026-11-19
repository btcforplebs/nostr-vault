// "Advanced" (VaultDashboardView advancedSection): Relay details only. Mesh settings lives in Your devices and Media
// Servers in Vault settings, one home each (RESEARCH/NV_VAULT_SETTINGS_DUPLICATES_2026_11_19.md). The browser's relay
// has no address or port, so Relay details is how long it has run and how long it took to start.
import { ExpandingRow, Line, Section } from "./parts.jsx"
import { uptimeLine } from "./StatusCard.jsx"

export function AdvancedSection({ start = performance.timeOrigin, startedInMs }) {
  return (
    <Section title="Advanced">
      <ExpandingRow icon="server" title="Relay details" value="">
        <Line title="Running for" value={uptimeLine(start).replace(/^Up /, "")} />
        {Number.isFinite(startedInMs) && <Line title="Started in" value={`${startedInMs} ms`} />}
        <Line title="Runs in" value="This browser tab" />
      </ExpandingRow>
    </Section>
  )
}
