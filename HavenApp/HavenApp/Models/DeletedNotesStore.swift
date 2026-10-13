import Foundation

/// The ids of the posts each account has deleted, kept on disk so a relay
/// that still serves one cannot bring it back after a restart. Fed by your
/// own deletes here and by your kind-5 requests arriving from your other
/// devices. One file per account, like `EngagementTracker`'s interaction
/// state. Twin: Android `DeletedNotesStore`.
final class DeletedNotesStore {
    static let shared = DeletedNotesStore(directory: DeletedNotesStore.defaultDirectory())

    private let directory: URL
    private let lock = NSLock()
    private var loaded: [String: Set<String>] = [:]
    /// In memory only: the ids this run has taken off the feed, per account,
    /// and the kind-5 events already handled. A relay replays your requests
    /// on every subscription; these make a replay cost a set lookup.
    private var appliedToFeed: [String: Set<String>] = [:]
    private var handledRequests: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    func ids(forAccount account: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return idsLocked(forAccount: account)
    }

    func contains(_ id: String, account: String) -> Bool {
        ids(forAccount: account).contains(id)
    }

    /// Adds `ids` for `account` and writes the file. Already-known ids are
    /// a no-op, so a kind 5 echoed by several relays costs one write at most.
    func markDeleted(_ ids: Set<String>, account: String) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let current = idsLocked(forAccount: account)
        let merged = current.union(ids)
        guard merged.count != current.count else { return }
        loaded[account] = merged
        let url = fileURL(forAccount: account)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(merged.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Claims the kind-5 event `requestId` and returns the posts it names
    /// that are not off the feed yet. Empty when nothing is left to do: the
    /// event was claimed before (another relay sent it too), or every post it
    /// names was already taken off. Call `releaseRequest` if the claimed
    /// event turns out not to count, so a genuine copy can still apply.
    func claimRequest(_ requestId: String, naming targets: Set<String>, account: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard handledRequests.insert(requestId).inserted else { return [] }
        return targets.subtracting(appliedToFeed[account] ?? [])
    }

    func releaseRequest(_ requestId: String) {
        lock.lock(); defer { lock.unlock() }
        handledRequests.remove(requestId)
    }

    /// Records that the feed no longer shows `ids` for `account`.
    func markAppliedToFeed(_ ids: Set<String>, account: String) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        appliedToFeed[account, default: []].formUnion(ids)
    }

    func fileURL(forAccount account: String) -> URL {
        let safeKey = account.isEmpty ? "owner" : account.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("deleted_notes_\(safeKey).json")
    }

    private func idsLocked(forAccount account: String) -> Set<String> {
        if let cached = loaded[account] { return cached }
        var ids = Set<String>()
        if let data = try? Data(contentsOf: fileURL(forAccount: account)),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            ids = Set(list)
        }
        loaded[account] = ids
        return ids
    }

    /// Application Support/Haven, where the other per-account files live.
    static func defaultDirectory() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        return appSupport.appendingPathComponent("Haven", isDirectory: true)
    }
}
