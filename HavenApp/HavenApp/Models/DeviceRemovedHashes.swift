import Foundation

/// Files the owner removed from THIS device with "Delete from this device"
/// (A3), by account (hex pubkey) and sha256. Every pass that fills the vault
/// on its own (Auto-Mirror from servers, the note-media pass, Moving-in and
/// setup imports) skips them, or the copy would be back within hours. Only
/// an explicit Save to Vault of that file takes it off the list.
///
/// One file, `removed_here.json` in the relay data folder, shared with the
/// engine (haven-go copyv2_removed_here.go: the copy v2 catch-up and the
/// mesh door skip listed files) and with Android `service/DeviceRemovedHashes.kt`.
/// Keep the shape `{"byAccount":{"<hex>":["<sha256>",…]}}` in step. Not in
/// Caches: a purged cache would quietly bring every removed file back.
///
/// A hash counts as removed under any account: the vault folder holds one
/// file per hash, so another account's pass would put the same file back.
struct DeviceRemovedHashes: Codable, Equatable {
    static let fileName = "removed_here.json"

    /// account (lowercase hex) -> sha256s (lowercase), in the order removed.
    var byAccount: [String: [String]] = [:]

    init() {}

    /// Lower-cases what another writer saved, as the engine does on read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: [String]].self, forKey: .byAccount) ?? [:]
        for (account, hashes) in raw {
            let key = account.lowercased()
            for sha in hashes where byAccount[key]?.contains(sha.lowercased()) != true {
                byAccount[key, default: []].append(sha.lowercased())
            }
        }
    }

    func contains(_ sha256: String) -> Bool {
        let key = sha256.lowercased()
        return byAccount.values.contains { $0.contains(key) }
    }

    /// Lists `sha256` under `owner`. No-op for a bad hash or key.
    mutating func add(_ sha256: String, owner: String) {
        let key = sha256.lowercased(), account = owner.lowercased()
        guard MediaSizeCache.isHash(key), MediaSizeCache.isHash(account) else { return }
        if byAccount[account]?.contains(key) == true { return }
        byAccount[account, default: []].append(key)
    }

    /// Save to Vault: wanted here again, so off every account's list.
    mutating func remove(_ sha256: String) {
        let key = sha256.lowercased()
        for account in Array(byAccount.keys) {
            byAccount[account]?.removeAll { $0 == key }
            if byAccount[account]?.isEmpty == true { byAccount[account] = nil }
        }
    }

    /// `hashes` without the removed ones, order kept.
    func keeping<S: Sequence>(_ hashes: S) -> [String] where S.Element == String {
        guard !byAccount.isEmpty else { return Array(hashes) }
        let removed = Set(byAccount.values.joined())
        return hashes.filter { !removed.contains($0.lowercased()) }
    }

    /// The list's file in `relayDataDir`, the engine's working folder.
    static func fileURL(relayDataDir: URL) -> URL {
        relayDataDir.standardizedFileURL.appendingPathComponent(fileName)
    }
}
