import Foundation
import Combine

/// Dedicated observable for relay logs, decoupled from RelayProcessManager
/// so that log updates only trigger redraws in LogsView — not every view
/// that observes RelayProcessManager.
///
/// All mutations are funnelled through the throttled `flush()` method to
/// avoid reentrant NSTableView delegate updates (SwiftUI List on macOS
/// uses NSTableView internally — mutating the data source mid-layout causes
/// "reentrant operation in its NSTableView delegate" warnings that will
/// become crashes in a future macOS release).
@MainActor
class LogStore: ObservableObject {
    @Published var logs: [RelayProcessManager.LogEntry] = []

    private var pendingLogs: [RelayProcessManager.LogEntry] = []
    private var logUpdateTimer: Timer?
    /// False while the UI is hidden (RelayProcessManager.enterBackground; on
    /// iOS, the app in the background). Entries are kept, at most `maxLogs`,
    /// and shown on return instead of each one scheduling a publish that
    /// redraws a screen nobody sees.
    var isUIActive = true
    private static let maxLogs = 1000

    func startThrottler() {
        stopThrottler()
        logUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
    }

    func stopThrottler() {
        logUpdateTimer?.invalidate()
        logUpdateTimer = nil
        flush()
    }

    /// Queue entries from a background thread (via Task { @MainActor })
    func enqueue(_ entries: [RelayProcessManager.LogEntry]) {
        pendingLogs.append(contentsOf: entries)
        guard isUIActive else { trimPending(); return }
        // If the throttler isn't running (e.g. popover closed / background),
        // schedule a one-shot flush so entries still appear in the Logs view.
        if logUpdateTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.flush()
            }
        }
    }

    /// Queue a single entry for the next throttled flush instead of
    /// mutating `logs` directly, preventing reentrant NSTableView updates.
    func append(_ entry: RelayProcessManager.LogEntry) {
        pendingLogs.append(entry)
        guard isUIActive else { trimPending(); return }
        // If the throttler isn't running, schedule a one-shot flush so
        // the entry still appears promptly.
        if logUpdateTimer == nil {
            DispatchQueue.main.async { [weak self] in
                self?.flush()
            }
        }
    }

    private func trimPending() {
        if pendingLogs.count > Self.maxLogs { pendingLogs.removeFirst(pendingLogs.count - Self.maxLogs) }
    }

    private func flush() {
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()

        logs.append(contentsOf: batch)
        if logs.count > Self.maxLogs {
            logs.removeFirst(max(0, logs.count - Self.maxLogs))
        }
    }
}
