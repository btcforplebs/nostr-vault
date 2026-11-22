import Foundation

/// The Vault dashboard's "Import notes" row detail. The import's result used
/// to vanish the moment it ended: the row showed the live status only while
/// importing, so a partial import ("…some may be missing") was never seen
/// (dashboard parity report gap H, 2026-11-22). Web keeps the line
/// (`KeepFullSection.jsx`). The last result now stays until the next run.
enum ImportRowDetail {
    /// - liveStatus: the running import's status line.
    /// - outcome: how the last import ended (nil: none ended since the app
    ///   started, or a new one is starting).
    /// - startFailed: the last request never started (it waited too long).
    /// - idle: "Since … Last ran …", the line with no result to keep.
    static func text(isImporting: Bool, liveStatus: String, outcome: ImportResult?,
                     startFailed: Bool, couldNotStartLine: String, idle: String) -> String {
        if isImporting { return liveStatus }
        if let outcome {
            // A complete import is the idle line's "Last ran just now".
            return outcome.isComplete ? idle : outcome.summary
        }
        return startFailed ? couldNotStartLine : idle
    }
}
