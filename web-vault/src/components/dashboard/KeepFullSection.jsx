// "Keep it full" (VaultDashboardView keepItFullSection): import your notes, back up your media, export your notes.
// The phone's Import media is left out: the page has no way to put files into its own vault's Blossom store.
// Import notes also looks for older versions of the user's lists (net/list-history-import.js); asking the history
// relays too is the user's switch, on by default (Logen 2026-11-04 14:34Z; off asks no relay at all), and that search
// can be skipped while it runs.
import { Row, RowButton, Section } from "./parts.jsx"
import { monthYear, relative } from "../../net/vault-history.js"

// The words, as the apps have them (ListHistoryScan.swift): a title, then a small line with "Lazarus" linking to its repo.
export const HISTORY_CHOICE = "Look up and back up my lists"
export const HISTORY_DETAIL = ["Finds older versions using ", "Lazarus", " spec"]
export const LAZARUS_URL = "https://github.com/dmnyc/lazarus"
export const HISTORY_DEFAULT_ON = true

export function KeepFullSection({ startDate, history = {}, importing, mediaBusy, exportBusy, status, onImport, onMedia, onExport,
  historyRelays = HISTORY_DEFAULT_ON, onHistoryRelays, onSkip }) {
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
          <span class="dash-check-text">
            <span class="dash-check-title">{HISTORY_CHOICE}</span>
            {/* A link inside a label is interactive content: clicking it opens the page, it does not flip the box. */}
            <small>{HISTORY_DETAIL[0]}<a href={LAZARUS_URL} target="_blank" rel="noopener noreferrer">{HISTORY_DETAIL[1]}</a>{HISTORY_DETAIL[2]}</small>
          </span>
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
