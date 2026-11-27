import Foundation

/// File sizes learned by asking a server (`HEAD <url>`), kept on disk by
/// sha256. A Blossom file's size never changes for a given hash, so an answer
/// is kept until the list is full; only the oldest are dropped.
///
/// Only a real size is stored. A lookup that failed, timed out, or came back
/// without a usable `Content-Length` is never cached: the row shows "—" and
/// the next look asks again.
///
/// Twins: Android `service/blossom/BlobSizeLookup.kt`, web `net/blob-size.js`.
struct MediaSizeCache: Codable, Equatable {
    /// Hashes kept; older answers are asked again when their row shows.
    static let maxEntries = 20_000

    struct Entry: Codable, Equatable {
        var size: Int64
        /// Unix seconds when it was learned (used only to drop the oldest).
        var at: Double
    }

    var entries: [String: Entry] = [:]

    func size(_ hash: String) -> Int64? { entries[hash.lowercased()]?.size }

    mutating func store(hash: String, size: Int64, now: Date = Date()) {
        let key = hash.lowercased()
        guard Self.isHash(key), size > 0 else { return }
        entries[key] = Entry(size: size, at: now.timeIntervalSince1970)
    }

    /// Keeps the newest `maxEntries`.
    func pruned() -> MediaSizeCache {
        guard entries.count > Self.maxEntries else { return self }
        let newest = entries.sorted { $0.value.at > $1.value.at }.prefix(Self.maxEntries)
        return MediaSizeCache(entries: Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) }))
    }

    static func isHash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The file size a `HEAD` answer gives, or nil when it gives none.
    /// Only a plain 200 counts: a 206 (a server treating it as a range) or any
    /// other status says nothing about the whole file, and a missing, zero or
    /// unparsable `Content-Length` is unknown, not empty.
    static func size(status: Int, contentLength: String?) -> Int64? {
        guard status == 200,
              let raw = contentLength?.trimmingCharacters(in: .whitespaces),
              let n = Int64(raw), n > 0 else { return nil }
        return n
    }
}
