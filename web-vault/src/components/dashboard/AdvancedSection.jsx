// "Advanced" (VaultDashboardView advancedSection): Relay details and Media servers. The browser's relay has no
// address or port, so Relay details is how long it has run and how long it took to start.
import { ExpandingRow, Line, Section, SettingRow } from "./parts.jsx"
import { uptimeLine } from "./StatusCard.jsx"

export function AdvancedSection({ start = performance.timeOrigin, startedInMs }) {
  return (
    <Section title="Advanced">
      <ExpandingRow icon="server" title="Relay details" value="">
        <Line title="Running for" value={uptimeLine(start).replace(/^Up /, "")} />
        {Number.isFinite(startedInMs) && <Line title="Started in" value={`${startedInMs} ms`} />}
        <Line title="Runs in" value="This browser tab" />
      </ExpandingRow>
      <SettingRow icon="photo" title="Media servers" href="#/settings/media-servers" />
    </Section>
  )
}
