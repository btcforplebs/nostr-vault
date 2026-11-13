import Foundation

/// The Vault screen saved per account (Logen 2026-11-13): the newest events
/// the Vault lists are built from, written when you leave the app or switch
/// accounts, read back the moment you open the app or switch to that account,
/// so the last screen shows at once and the refresh tops it up quietly.
enum VaultSnapshotStore {
    /// The account the events in memory belong to. Needed because by the time
    /// a switch is heard, `activeHexPubkey` already names the new account.
    nonisolated(unsafe) static var eventsOwner = ""
    /// The account whose saved screen is in memory now; nil once none was
    /// found. The Vault list shows a saved screen at once (VaultListSwap).
    nonisolated(unsafe) static var restoredAccount: String?

    private static let queue = DispatchQueue(label: "nv.vault-snapshot", qos: .utility)

    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("vault-snapshots", isDirectory: true)
    }

    static func url(account hex: String) -> URL? {
        guard let name = VaultSnapshotRules.fileName(account: hex) else { return nil }
        return folder?.appendingPathComponent(name)
    }

    /// Writes off the main thread; the newest `VaultSnapshotRules.keep` only.
    /// `wait`: the app is quitting, so the write finishes before this returns.
    static func save(_ events: [NostrEvent], account hex: String, wait: Bool = false) {
        guard let url = url(account: hex), !events.isEmpty else { return }
        let write = {
            let kept = VaultSnapshotRules.newest(events, createdAt: \.created_at)
            guard let data = try? JSONEncoder().encode(kept) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if wait { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// The saved events, newest first; empty when there are none. Waits for
    /// a write still on its way, so a quick switch back reads the latest.
    static func load(account hex: String) -> [NostrEvent] {
        guard let url = url(account: hex) else { return [] }
        return queue.sync {
            guard let data = try? Data(contentsOf: url),
                  let events = try? JSONDecoder().decode([NostrEvent].self, from: data) else { return [] }
            return events
        }
    }
}

extension NostrService {
    /// Saves the events in memory as the screen of the account they belong to.
    func saveVaultSnapshot(wait: Bool = false) {
        let owner = VaultSnapshotStore.eventsOwner.isEmpty ? activeHexPubkey : VaultSnapshotStore.eventsOwner
        VaultSnapshotStore.save(events, account: owner, wait: wait)
    }

    /// Puts the active account's saved screen in memory, if nothing is there
    /// yet. Marked seen, so the refresh that follows adds only what's new.
    func restoreVaultSnapshot() {
        let owner = activeHexPubkey
        VaultSnapshotStore.eventsOwner = owner
        VaultSnapshotStore.restoredAccount = nil
        guard events.isEmpty else { return }
        let saved = VaultSnapshotStore.load(account: owner)
        guard !saved.isEmpty else { return }
        VaultSnapshotStore.restoredAccount = owner.lowercased()
        for event in saved { _ = markSeen(event.id) }
        events = saved
        eventUpdateSubject.send()
    }
}
