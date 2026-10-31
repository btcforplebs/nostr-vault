import Foundation

/// The photo screen's "which Blossom servers hold this file" answers, kept on
/// disk for a day so reopening a photo, or relaunching the app, does not ask
/// every server again.
///
/// Answers are stored as "present" / "absent" per server. "Could not ask" is
/// never stored: a server that was down should be asked again next time, not
/// shown as "?" for a day.
struct BlossomPresenceDisk: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Unix seconds of the check.
        var checkedAt: Double
        /// Server URL to "present" or "absent".
        var servers: [String: String]
    }

    static let maxAge: TimeInterval = 24 * 60 * 60
    /// Newest files kept; older ones are asked again when opened.
    static let maxEntries = 5000

    var entries: [String: Entry] = [:]

    /// Whether the answer for `hash` is young enough to show without asking.
    func isFresh(_ hash: String, now: Date = Date()) -> Bool {
        guard let entry = entries[hash] else { return false }
        return now.timeIntervalSince1970 - entry.checkedAt < Self.maxAge
    }

    /// Stores one check. Only full answers are kept: if any server could not
    /// be asked (nil in `servers`) the entry is dropped instead.
    mutating func store(hash: String, servers: [String: Bool?], now: Date = Date()) {
        guard !servers.isEmpty, servers.values.allSatisfy({ $0 != nil }) else {
            entries[hash] = nil
            return
        }
        entries[hash] = Entry(checkedAt: now.timeIntervalSince1970,
                              servers: servers.mapValues { $0 == true ? "present" : "absent" })
    }

    /// Drops answers older than a day and keeps the newest `maxEntries`.
    func pruned(now: Date = Date()) -> BlossomPresenceDisk {
        let cutoff = now.timeIntervalSince1970 - Self.maxAge
        var kept = entries.filter { $0.value.checkedAt > cutoff }
        if kept.count > Self.maxEntries {
            let newest = kept.sorted { $0.value.checkedAt > $1.value.checkedAt }.prefix(Self.maxEntries)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return BlossomPresenceDisk(entries: kept)
    }
}
