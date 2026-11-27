import Foundation

/// Files the owner removed from THIS device with "Delete from this device"
/// (A3), by sha256. Every pass that fills the vault on its own (Auto-Mirror
/// from servers, the note-media pass, Moving-in and setup imports) skips
/// them, or the copy would be back within hours. Only an explicit Save to
/// Vault of that file takes it off the list.
///
/// One list per vault owner, on disk beside the vault folder, where the
/// engine reads it too (haven-go removed_here.go: the mesh copy catch-up and
/// the mesh door skip listed files). Not in Caches: a purged cache would
/// quietly bring every removed file back.
/// Twin: Android `service/DeviceRemovedHashes.kt`.
struct DeviceRemovedHashes: Codable, Equatable {
    /// sha256 (lowercase) -> Unix seconds when it was removed here.
    var removed: [String: Double] = [:]

    func contains(_ sha256: String) -> Bool { removed[sha256.lowercased()] != nil }

    mutating func add(_ sha256: String, now: Date = Date()) {
        let key = sha256.lowercased()
        guard MediaSizeCache.isHash(key) else { return }
        removed[key] = now.timeIntervalSince1970
    }

    mutating func remove(_ sha256: String) { removed[sha256.lowercased()] = nil }

    /// `hashes` without the removed ones, order kept.
    func keeping<S: Sequence>(_ hashes: S) -> [String] where S.Element == String {
        removed.isEmpty ? Array(hashes) : hashes.filter { !contains($0) }
    }

    /// The file for `owner`'s list: `removed_here/<owner>.json` in the
    /// folder that holds `vault` (the Blossom folder, BLOSSOM_PATH).
    static func fileURL(owner: String, vault: URL) -> URL? {
        let key = owner.lowercased()
        guard MediaSizeCache.isHash(key) else { return nil }
        return vault.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("removed_here", isDirectory: true)
            .appendingPathComponent("\(key).json")
    }
}
