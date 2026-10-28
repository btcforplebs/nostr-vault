// "Keep it full" (VaultDashboardView keepItFullSection): import your notes, back up your media, export your notes.
// The phone's Import media is left out: the page has no way to put files into its own vault's Blossom store.
import { Row, RowButton, Section } from "./parts.jsx"
import { monthYear, relative } from "../../net/vault-history.js"

export function KeepFullSection({ startDate, history = {}, importing, mediaBusy, exportBusy, status, onImport, onMedia, onExport }) {
  const busy = !!importing || mediaBusy || exportBusy
  return (
    <Section title="Keep it full">
      <Row icon="down" title="Import notes" progress={importing ? importing.progress : undefined}
        detail={importing ? importing.text : `Since ${monthYear(startDate)}. ${history.notesImport ? `Last ran ${relative(history.notesImport)}.` : "Never ran."}`}>
        <RowButton title="Import" busy={!!importing} disabled={busy} onClick={onImport} />
      </Row>
      <Row icon="stack" title="Back up media" detail={history.mediaBackup ? `Last made ${relative(history.mediaBackup)}.` : "Never made."}>
        <RowButton title="Back up" busy={mediaBusy} disabled={busy} onClick={onMedia} />
      </Row>
      <Row icon="up" title="Export notes" detail={history.notesBackup ? `Last made ${relative(history.notesBackup)}.` : "Never made."}>
        <RowButton title="Export" busy={exportBusy} disabled={busy} onClick={onExport} />
      </Row>
      {status && <div class={`dash-row dash-note${status.error ? " error" : ""}`} role="status">{status.text}</div>}
    </Section>
  )
}
