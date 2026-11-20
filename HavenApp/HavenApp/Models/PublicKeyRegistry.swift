import Foundation

/// Accounts whose secret key we have seen out in the open, in a profile we
/// already loaded (`SecretKeyLeak`). Anyone can post as them, so the web gate
/// treats them as outside and their profile says so.
///
/// Memory only: never written to disk, never sent. It holds pubkeys, not the
/// keys. Rebuilt each run from profiles as they load (the disk cache too).
final class PublicKeyRegistry: @unchecked Sendable {
    static let shared = PublicKeyRegistry()

    /// Posted on the main queue when a pubkey is newly marked, so an open
    /// profile can show its label.
    static let changed = Notification.Name("PublicKeyRegistry.changed")

    private let lock = NSLock()
    private var keys = Set<String>()

    /// Marks `pubkeys` (hex). Returns whether any was new.
    @discardableResult
    func mark(_ pubkeys: [String]) -> Bool {
        guard !pubkeys.isEmpty else { return false }
        lock.lock()
        var added = false
        for key in pubkeys where keys.insert(key.lowercased()).inserted { added = true }
        lock.unlock()
        if added {
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
        }
        return added
    }

    func isPublic(_ pubkey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !keys.isEmpty && keys.contains(pubkey.lowercased())
    }

    /// For tests.
    func reset() {
        lock.lock()
        keys.removeAll()
        lock.unlock()
    }
}
