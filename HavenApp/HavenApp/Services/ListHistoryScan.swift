import Foundation

/// Moving in's look for older versions of the owner's lists (haven-go
/// list_history_scan.go): the switch the app sets, and the log lines it reads.
/// The user ticks it (off by default, Logen 2026-11-04); what it finds goes
/// to the vault's import store, where Recover a List sees it. Never published.
enum ListHistoryScan {
    /// haven-go listHistoryOptInEnv: "1" runs the scan for this import.
    static let optInEnv = "HAVEN_IMPORT_LIST_HISTORY"

    /// The checkbox, word for word (Logen 2026-11-04).
    static let optInLabel = "Also look for older versions of my lists on history relays (hist.nostr.land, relay.ditto.pub). They will see your IP asked. Adds about a minute."

    /// The /lists filter `#v` value that asks for the imported versions only.
    static let importedFilterValue = "imported"

    static let lookingStatus = "Looking for older versions of your lists..."
    /// Read by ImportTourStage as "Looking through your history…".
    static let notesNextStatus = "Looking through notes..."

    /// What the wipe alarm judges: only the versions the vault filed itself.
    /// An old clobber found on the relays is not a new wipe (Tron, PR 1639).
    static func alarmInput(_ versions: [ListVersion], imported: Set<String>) -> [ListVersion] {
        imported.isEmpty ? versions : versions.filter { !imported.contains($0.id) }
    }

    private static let marker = "📜 "

    /// Reads one relay log line. true when it was a scan line (nothing else
    /// in it to parse).
    static func collect(from line: String, into batch: inout RelayLogParser.BatchedStateUpdate) -> Bool {
        guard let r = line.range(of: marker) else { return false }
        let text = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("looking for older versions") {
            batch.listHistoryScanning = true
            batch.importStatusMessage = lookingStatus
        } else if text.hasPrefix("skipping") {
            batch.listHistoryScanning = false
        } else if !text.isEmpty {
            batch.listHistoryScanning = false
            batch.listHistoryNote = text
            // The notes come next: say so, rather than leaving the scan's line up.
            batch.importStatusMessage = notesNextStatus
        }
        return true
    }
}
