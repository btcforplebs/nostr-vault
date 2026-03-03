import Foundation
import Combine

/// Dedicated observable for relay logs, decoupled from RelayProcessManager
/// so that log updates only trigger redraws in LogsView — not every view
/// that observes RelayProcessManager.
@MainActor
class LogStore: ObservableObject {
    @Published var logs: [RelayProcessManager.LogEntry] = []

    private var pendingLogs: [RelayProcessManager.LogEntry] = []
    private var logUpdateTimer: Timer?

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
    }

    /// Immediately append a single entry (already on MainActor)
    func append(_ entry: RelayProcessManager.LogEntry) {
        logs.append(entry)
        if logs.count > 1000 {
            logs.removeFirst(max(0, logs.count - 1000))
        }
    }

    private func flush() {
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()

        logs.append(contentsOf: batch)
        if logs.count > 1000 {
            logs.removeFirst(max(0, logs.count - 1000))
        }
    }
}
