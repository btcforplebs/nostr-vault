import Foundation

/// Moving in's look for older versions of the owner's lists (haven-go
/// list_history_scan.go): the switch the app sets, and the log lines it reads.
/// On by default (Logen 2026-11-04, 14:34Z); off skips every history relay.
/// What it finds goes to the vault's import store, where Recover a List sees
/// it. Never published.
enum ListHistoryScan {
    /// haven-go listHistoryOptInEnv: "1" runs the scan for this import.
    static let optInEnv = "HAVEN_IMPORT_LIST_HISTORY"
    /// haven-go listHistoryAccountEnv: the hex pubkey of the account moving
    /// in, the only one the history relays are asked about (Tron, PR 1641).
    static let accountEnv = "HAVEN_IMPORT_LIST_HISTORY_ACCOUNT"

    /// Every Moving in starts with the scan on (Logen 2026-11-04, 14:34Z).
    static let defaultOn = true

    /// The switch, word for word (Logen 2026-11-04, 14:34Z): title, then a
    /// small line with "Lazarus" linking to its repo.
    static let optInLabel = "Look up and back up my lists"
    static let optInDetailBefore = "Finds older versions using "
    static let optInDetailLink = "Lazarus"
    static let optInDetailAfter = " spec"
    static let lazarusURL = URL(string: "https://github.com/dmnyc/lazarus")!
    static var optInDetail: String { optInDetailBefore + optInDetailLink + optInDetailAfter }

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
        // Byte check first: this runs on every relay log line (RelayLogBytes).
        guard RelayLogBytes.contains(line, marker), let r = line.range(of: marker) else { return false }
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
