import Foundation

/// Kind-0 profiles parsed but not yet written to `NostrService.profiles`.
/// Each write to that `@Published` dictionary redraws every screen that
/// watches the service, hidden tabs included, so a burst of profiles (the
/// globe's faces, a feed page) is written in one go: one redraw for the
/// batch, not one per profile (iPhone heat, 10/21).
struct ProfileWriteBatch {
    private(set) var pending: [String: FeedProfile] = [:]

    var isEmpty: Bool { pending.isEmpty }

    /// What a new kind 0 for `pubkey` is compared with: the one waiting
    /// here, else the one stored.
    func current(_ pubkey: String, stored: [String: FeedProfile]) -> FeedProfile? {
        pending[pubkey] ?? stored[pubkey]
    }

    mutating func add(_ profile: FeedProfile) {
        pending[profile.pubkey] = profile
    }

    /// Writes every waiting profile into `profiles` with one assignment and
    /// returns whose changed. A profile written there directly since it was
    /// parsed from a newer kind 0 is kept.
    mutating func flush(into profiles: inout [String: FeedProfile]) -> [String] {
        guard !pending.isEmpty else { return [] }
        var next = profiles
        var written: [String] = []
        for (pubkey, profile) in pending {
            if let stored = next[pubkey]?.metadataCreatedAt, let mine = profile.metadataCreatedAt, stored > mine { continue }
            next[pubkey] = profile
            written.append(pubkey)
        }
        pending.removeAll(keepingCapacity: true)
        if !written.isEmpty { profiles = next }
        return written
    }
}

/// Writes a cache file one save at a time. A save asked for while one is
/// running is held, and a newer one replaces it, so at most one value is
/// being written and one waiting. Saves used to start on a global queue
/// every 5 s; with a 26 MB profile cache each took longer than that, they
/// piled up, and the copies they held ran the iPhone out of memory during
/// an account switch (11/14).
final class LatestOnlySave<Value> {
    private let lock = NSLock()
    private var running = false
    private var held: Value?
    private let queue: DispatchQueue
    private let write: (Value) -> Void

    init(queue: DispatchQueue, write: @escaping (Value) -> Void) {
        self.queue = queue
        self.write = write
    }

    func save(_ value: Value) {
        lock.lock()
        if running {
            held = value
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { self.drain(value) }
    }

    private func drain(_ first: Value) {
        var next: Value? = first
        while let value = next {
            autoreleasepool { write(value) }
            lock.lock()
            next = held
            held = nil
            if next == nil { running = false }
            lock.unlock()
        }
    }
}
