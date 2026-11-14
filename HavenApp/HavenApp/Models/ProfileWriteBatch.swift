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

/// One profile as stored on disk: the profile and when it last arrived or
/// changed (unix seconds), which the cap keeps the newest of.
struct CachedProfile: Codable, Equatable {
    var p: FeedProfile
    var s: Int64
}

/// The profile cache on disk, split into 256 shard files by the first two
/// hex characters of the pubkey, and capped.
///
/// A save compares the profiles with those handed to the last save and
/// rewrites only the shards where one changed, instead of encoding every
/// profile ever seen (26 MB on Logen's iPhone, 11/14). Profiles past `cap`
/// are left off disk, oldest first; `keep` (the accounts' own and the
/// active account's follows) is never left off. Runs on one queue.
struct ProfileCacheShards {
    static let cap = 10_000

    /// The profiles handed to the last save (or load).
    private(set) var previous: [String: FeedProfile] = [:]
    /// What is on disk: pubkey → when it last arrived or changed.
    private(set) var onDisk: [String: Int64] = [:]
    /// Every shard must be written: a first save after the single-file cache.
    private(set) var writeAll = false

    static func shard(of pubkey: String) -> String {
        let head = pubkey.prefix(2).lowercased()
        return head.count == 2 && head.allSatisfy(\.isHexDigit) ? head : "zz"
    }

    /// Starts from the shard files' contents.
    init(loaded: [String: CachedProfile]) {
        previous = loaded.mapValues(\.p)
        onDisk = loaded.mapValues(\.s)
    }

    /// Starts from the old single-file cache: everything is written once,
    /// stamped with its kind 0's `created_at` (0 if unknown), so the first
    /// cap keeps the profiles updated most recently.
    init(legacy: [String: FeedProfile]) {
        previous = legacy
        onDisk = legacy.mapValues { $0.metadataCreatedAt ?? 0 }
        writeAll = true
    }

    /// The shards to write, each with its full contents (empty = delete).
    mutating func plan(_ profiles: [String: FeedProfile], now: Int64, keep: Set<String>, cap: Int = Self.cap) -> [String: [String: CachedProfile]] {
        var dirty = Set<String>()
        for (pubkey, profile) in profiles where previous[pubkey] != profile {
            onDisk[pubkey] = now
            dirty.insert(Self.shard(of: pubkey))
        }
        for pubkey in previous.keys where profiles[pubkey] == nil {
            if onDisk.removeValue(forKey: pubkey) != nil { dirty.insert(Self.shard(of: pubkey)) }
        }
        previous = profiles

        if onDisk.count > cap {
            let spare = onDisk.filter { !keep.contains($0.key) }
            let room = max(0, cap - (onDisk.count - spare.count))
            if spare.count > room {
                let oldest = spare.sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
                for (pubkey, _) in oldest.prefix(spare.count - room) {
                    onDisk.removeValue(forKey: pubkey)
                    dirty.insert(Self.shard(of: pubkey))
                }
            }
        }

        var out: [String: [String: CachedProfile]] = [:]
        if writeAll {
            for n in 0..<256 { out[String(format: "%02x", n)] = [:] }
            out["zz"] = [:]
            writeAll = false
        } else {
            for shard in dirty { out[shard] = [:] }
        }
        for (pubkey, stamp) in onDisk {
            let shard = Self.shard(of: pubkey)
            guard out[shard] != nil, let profile = profiles[pubkey] else { continue }
            out[shard]?[pubkey] = CachedProfile(p: profile, s: stamp)
        }
        return out
    }
}
