import Foundation

/// The DM history on disk, one JSON file per account (`dm_cache_<key>.json`).
///
/// The format is unchanged — an array of `DMConversation` — so a cache written
/// by any earlier build loads as it is. What changed is when the work runs:
/// encoding and writing happen on `DMCacheWriter`'s queue, coalesced, and the
/// launch decode happens off the main thread. Both used to run on main, the
/// whole history for every message, so the stutter grew with the history.
enum DMCacheFile {
    /// Every message is written: there is no cap. The inbox has no paged
    /// "load older" fetch, so a message cut from this file would not come back.
    static func encode(_ conversations: [DMConversation]) throws -> Data {
        try JSONEncoder().encode(conversations)
    }

    /// nil when the file is missing or unreadable; never throws at the caller.
    static func decode(_ data: Data) -> [DMConversation]? {
        try? JSONDecoder().decode([DMConversation].self, from: data)
    }

    /// Reads the cache at `url`. A file that is there but will not decode is
    /// moved aside (`asideURL`) rather than left for the next save to
    /// overwrite: the history in it may still be recoverable by hand.
    static func read(_ url: URL, now: Date = Date(),
                     fileManager: FileManager = .default) -> [DMConversation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let conversations = decode(data) { return conversations }
        try? fileManager.moveItem(at: url, to: asideURL(for: url, at: now))
        return []
    }

    /// `dm_cache_<key>.json` → `dm_cache_<key>.unreadable-<unix time>.json`,
    /// beside it. Never the name a save writes to.
    static func asideURL(for url: URL, at date: Date) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).unreadable-\(Int(date.timeIntervalSince1970)).json")
    }

    /// The cache as loaded, plus whatever reached memory while it was being
    /// read (a send, or a message from the relay). Nothing from either side is
    /// dropped: messages are unioned by id and the cached copy wins a tie.
    /// Unread is added only for messages the cache did not already hold — a
    /// re-delivered message is not new, so it cannot come back unread.
    static func merge(loaded: [DMConversation], live: [DMConversation]) -> [DMConversation] {
        guard !live.isEmpty else { return loaded }
        var result = loaded
        var index = Dictionary(uniqueKeysWithValues: loaded.enumerated().map { ($1.id, $0) })
        for conversation in live {
            guard let at = index[conversation.id] else {
                index[conversation.id] = result.count
                result.append(conversation)
                continue
            }
            var known = Set(result[at].messages.map(\.id))
            var messages = result[at].messages
            var newIncoming = 0
            for message in conversation.messages where known.insert(message.id).inserted {
                messages.append(message)
                if !message.isFromMe { newIncoming += 1 }
            }
            messages.sort { $0.timestamp < $1.timestamp }
            result[at].messages = messages
            result[at].unreadCount += min(conversation.unreadCount, newIncoming)
        }
        return result
    }
}

/// Writes files on one background queue, coalesced per file: however many
/// saves arrive within `delay`, each file is encoded and written once, with
/// the newest snapshot. Callers hand over a value snapshot and return at once.
final class DMCacheWriter: @unchecked Sendable {
    typealias Encode = @Sendable () throws -> Data
    typealias Write = @Sendable (Data, URL) throws -> Void

    private let queue = DispatchQueue(label: "com.haven.dm-cache-writer", qos: .userInitiated)
    private let delay: TimeInterval
    private let write: Write
    // Touched only on `queue`.
    private var pending: [URL: Encode] = [:]
    private var order: [URL] = []
    private var flushScheduled = false

    init(delay: TimeInterval = 1.0, write: @escaping Write) {
        self.delay = delay
        self.write = write
    }

    /// Replaces any save of `url` not yet written. Each file keeps its own
    /// snapshot, so a save for the account just left still lands in its file.
    func schedule(_ url: URL, encode: @escaping Encode) {
        queue.async {
            if self.pending.updateValue(encode, forKey: url) == nil {
                self.order.append(url)
            }
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            self.queue.asyncAfter(deadline: .now() + self.delay) { self.flushPending() }
        }
    }

    /// Write everything pending now, without waiting for the delay.
    func flush() {
        queue.async { self.flushPending() }
    }

    /// Write everything pending and return when it is on disk. Blocks the
    /// caller (GCD may run it on the calling thread): app exit only.
    func flushAndWait() {
        queue.sync { self.flushPending() }
    }

    /// Writes everything pending, then runs `work` on the same queue — a read
    /// of a file can never overtake a save of it.
    func flushThen(_ work: @escaping @Sendable () -> Void) {
        queue.async {
            self.flushPending()
            work()
        }
    }

    private func flushPending() {
        flushScheduled = false
        let urls = order
        let jobs = pending
        order.removeAll()
        pending.removeAll()
        for url in urls {
            guard let encode = jobs[url], let data = try? encode() else { continue }
            try? write(data, url)
        }
    }
}
