// One group of a Settings page, as the index draws them: its label (with an (i) when given), its rows, and the
// phone's footer line under it.
import { SettingInfo } from "../../components/SettingInfo.jsx"

export function Section({ label, info, note, children }) {
  return (
    <section class="settings-group">
      <div class="section-label">{label}{info && <SettingInfo topic={info} />}</div>
      <div class="settings-rows">{children}</div>
      {note && <p class="settings-note muted small">{note}</p>}
    </section>
  )
}
