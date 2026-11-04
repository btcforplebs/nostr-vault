// "Keep it full" (VaultDashboardView keepItFullSection): import your notes, back up your media, export your notes.
// The phone's Import media is left out: the page has no way to put files into its own vault's Blossom store.
// Import notes also looks for older versions of the user's lists (net/list-history-import.js); asking the history
// relays too is the user's tick, off by default (Logen 2026-11-04), and that search can be skipped while it runs.
import { Row, RowButton, Section } from "./parts.jsx"
import { monthYear, relative } from "../../net/vault-history.js"
import { HISTORY_RELAYS } from "../../net/list-history-import.js"

const hosts = HISTORY_RELAYS.map(u => u.replace(/^wss?:\/\//, "")).join(", ")
export const HISTORY_CHOICE = `Also look for older versions of my lists on history relays (${hosts}). They will see your IP asked. Adds about a minute.`

export function KeepFullSection({ startDate, history = {}, importing, mediaBusy, exportBusy, status, onImport, onMedia, onExport,
  historyRelays = false, onHistoryRelays, onSkip }) {
  const busy = !!importing || mediaBusy || exportBusy
  return (
    <Section title="Keep it full">
      <Row icon="down" title="Import notes" progress={importing ? importing.progress : undefined}
        detail={importing ? importing.text : `Since ${monthYear(startDate)}. ${history.notesImport ? `Last ran ${relative(history.notesImport)}.` : "Never ran."}`}>
        {importing?.skippable && onSkip
          ? <button type="button" class="dash-button small" onClick={onSkip}>Skip</button>
          : <RowButton title="Import" busy={!!importing} disabled={busy} onClick={onImport} />}
      </Row>
      {onHistoryRelays && (
        <label class="dash-row dash-check">
          <input type="checkbox" checked={historyRelays} disabled={!!importing} onChange={e => onHistoryRelays(e.currentTarget.checked)} />
          <span>{HISTORY_CHOICE}</span>
        </label>
      )}
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
