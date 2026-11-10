import Foundation

/// The DM history on disk, one JSON file per account (`dm_cache_<key>.json`).
///
/// The format is unchanged — an array of `DMConversation` — so a cache written
/// by any earlier build loads as it is. What changed is when the work runs:
/// encoding and writing happen on `DMCacheWriter`'s queue, coalesced, and the
/// launch decode happens off the main thread. Both used to run on main, the
/// whole history for every message, so the stutter grew with the history.
enum DMCacheFile {
    /// Newest messages kept on disk per conversation. Loading never drops
    /// anything: a larger file written by an older build loads in full, and the
    /// cap applies from its next save. Older messages stay on the relay.
    static let maxStoredMessagesPerConversation = 2_000

    /// What gets written: each conversation's newest `limit` messages.
    /// `messages` is kept oldest first (`DMService` sorts on insert), so the
    /// newest are the suffix.
    static func capped(_ conversations: [DMConversation],
                       limit: Int = maxStoredMessagesPerConversation) -> [DMConversation] {
        conversations.map { conversation in
            guard conversation.messages.count > limit else { return conversation }
            var trimmed = conversation
            trimmed.messages = Array(conversation.messages.suffix(limit))
            return trimmed
        }
    }

    static func encode(_ conversations: [DMConversation],
                       limit: Int = maxStoredMessagesPerConversation) throws -> Data {
        try JSONEncoder().encode(capped(conversations, limit: limit))
    }

    /// nil when the file is missing or unreadable; never throws at the caller.
    static func decode(_ data: Data) -> [DMConversation]? {
        try? JSONDecoder().decode([DMConversation].self, from: data)
    }

    /// The cache as loaded, plus whatever reached memory while it was being
    /// read (a send, or a message from the relay). Nothing from either side is
    /// dropped: messages are unioned by id, the cached copy wins a tie, and the
    /// unread counts add — the live count only ever counts arrivals.
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
            for message in conversation.messages where known.insert(message.id).inserted {
                messages.append(message)
            }
            messages.sort { $0.timestamp < $1.timestamp }
            result[at].messages = messages
            result[at].unreadCount += conversation.unreadCount
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
