import Foundation

/// Your deleted posts, kept on this device for 30 days so they can be
/// un-deleted. One JSON file per account (hex pubkey), so switching accounts
/// never shows or re-posts another account's posts.
///
/// Only the device that pressed Delete holds a copy: other devices get the
/// kind 5 and drop the post without one.
final class DeletedPostsStore {
    static let shared = DeletedPostsStore(directory: DeletedPostsStore.defaultDirectory)

    /// How long a deleted post stays un-deletable.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    private static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("deleted-posts", isDirectory: true)
    }

    /// The account's saved posts, most recently deleted first. Posts past the
    /// 30 days are dropped here, and from disk.
    func posts(account: String, now: Date = Date()) -> [DeletedPost] {
        lock.lock(); defer { lock.unlock() }
        let stored = read(account: account)
        let kept = Self.unexpired(stored, now: now)
        if kept.count != stored.count { write(kept, account: account) }
        return kept
    }

    /// Saves a copy. A second delete of the same id replaces the first copy.
    func save(_ post: DeletedPost, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var posts = read(account: post.pubkey).filter { $0.id != post.id }
        posts.insert(post, at: 0)
        write(Self.unexpired(posts, now: now), account: post.pubkey)
    }

    /// Drops a copy: after un-delete, or Delete forever.
    func remove(id: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        let posts = read(account: account)
        let kept = posts.filter { $0.id != id }
        if kept.count != posts.count { write(kept, account: account) }
    }

    /// Posts deleted less than `retention` ago, most recent first.
    static func unexpired(_ posts: [DeletedPost], now: Date) -> [DeletedPost] {
        posts
            .filter { now.timeIntervalSince($0.deletedAt) < retention }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    // MARK: - Disk

    /// nil unless `account` is a 64-character hex pubkey, so nothing else can
    /// become part of a file path.
    private func fileURL(account: String) -> URL? {
        let hex = account.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return directory.appendingPathComponent("\(hex).json")
    }

    private func read(account: String) -> [DeletedPost] {
        guard let url = fileURL(account: account),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([DeletedPost].self, from: data)) ?? []
    }

    private func write(_ posts: [DeletedPost], account: String) {
        guard let url = fileURL(account: account) else { return }
        if posts.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(posts) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
