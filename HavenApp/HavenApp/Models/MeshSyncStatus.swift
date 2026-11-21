import Foundation

/// The mesh catch-ups Settings › Your Devices shows: when each copied-from
/// device last synced (`lastAt`, Unix s, the copy record's own map), the one
/// running now, the ones Sync now still has to start, and the last failure
/// per device (the engine's `COPY` error code, `unreachable` when it could
/// not be dialled) until a later one finishes. Android: `MeshSyncState`.
struct MeshSyncState: Equatable {
    var lastAt: [String: Int] = [:]
    var running: String?
    var queued: [String] = []
    var failed: [String: String] = [:]
}

/// One row per device this one copies from, with when it last synced and
/// what it is doing, and one Sync now for all of them. Pure, so
/// MediaLogicTests checks it. Twin of Android's `MeshSyncStatus` (3.3.0 D1).
enum MeshSyncStatus {
    enum State: Equatable { case syncing, waiting, failed, upToDate }

    struct Row: Equatable, Identifiable {
        var npub: String
        var name: String
        var lastLine: String
        var state: State
        var stateLine: String
        var id: String { npub }
    }

    /// The listed devices this one has copied from, in the list's order;
    /// the rest have no catch-up to run.
    static func rows(devices: [MeshDevice], sync: MeshSyncState, progress: MeshCopyV2.Progress?, now: Int) -> [Row] {
        devices.filter { sync.lastAt[$0.npub] != nil || $0.npub == sync.running }.map { d in
            let s = state(d.npub, sync: sync)
            return Row(npub: d.npub, name: d.displayName, lastLine: lastLine(sync.lastAt[d.npub] ?? 0, now: now),
                       state: s, stateLine: stateLine(s, error: sync.failed[d.npub], progress: progress))
        }
    }

    static func state(_ npub: String, sync: MeshSyncState) -> State {
        if sync.running == npub { return .syncing }
        if sync.queued.contains(npub) { return .waiting }
        if sync.failed[npub] != nil { return .failed }
        return .upToDate
    }

    /// "Last synced 5 min ago" / "Never synced".
    static func lastLine(_ lastAt: Int, now: Int) -> String {
        guard lastAt > 0 else { return "Never synced" }
        let ago = MyDevicesStatus.agoText(Date(timeIntervalSince1970: TimeInterval(lastAt)),
                                          now: Date(timeIntervalSince1970: TimeInterval(now)))
        return "Last synced " + ago
    }

    static func stateLine(_ state: State, error: String?, progress: MeshCopyV2.Progress?) -> String {
        switch state {
        case .syncing:
            guard let p = progress, p.stage == "fetching", p.bytes.total > 0 else { return "Syncing…" }
            return "Syncing… \(min(100, max(0, p.bytes.done * 100 / p.bytes.total)))%"
        case .waiting:
            return "Waiting to sync"
        case .failed:
            return error == "unreachable" ? "Couldn't reach it. Make sure it's on and Nostr Vault is open."
                : "The last sync didn't finish."
        case .upToDate:
            return "Up to date"
        }
    }

    /// Sync now: after setup, with a device to sync, and nothing already
    /// running or waiting.
    static func syncEnabled(setupDone: Bool, rows: [Row], sync: MeshSyncState) -> Bool {
        setupDone && !rows.isEmpty && sync.running == nil && sync.queued.isEmpty
    }

    /// Who Sync now catches up with, in turn: every device copied from, the
    /// longest ago first, due or not, except the one a copy is still pending
    /// with (that copy resumes on its own) and the one already running.
    static func syncNowOrder(copied: [String: Int], pending: String?, running: String?) -> [String] {
        copied.filter { $0.key != pending && $0.key != running }
            .sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// Sync now's queue after adding `peers`: no repeats, not the running one.
    static func queued(_ current: [String], adding peers: [String], running: String?) -> [String] {
        var seen = Set<String>()
        return (current + peers).filter { $0 != running && seen.insert($0).inserted }
    }

    static let header = "Sync with your vaults"
    static let footer = "Your devices catch up on their own every 15 minutes while Nostr Vault is open. "
        + "Sync now does it right away, with each of them in turn."
    static let syncNow = "Sync now"
}
