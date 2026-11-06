import Foundation

/// Which local files and settings belong to one account, for Delete Account
/// on that account's page. The app names per-account caches and settings
/// after the account's hex pubkey or its npub (`deleted_notes_<npub>.json`,
/// `<hex>.json`, `followersSeenAt.<hex>`), so a name holding either one is
/// that account's. Pure, so it is unit-tested; `AppDataWipe.forgetAccount`
/// does the deleting.
enum AccountDataSweep {
    /// Folders never walked: the vault database and config.json belong to
    /// the main account and are not named after one account.
    static let skipped: Set<String> = ["haven_database", "config.json"]

    /// True when `name` holds the account's hex pubkey or npub (any case).
    /// A malformed key matches nothing, so a bad input can't sweep broadly.
    static func belongs(_ name: String, hex: String, npub: String) -> Bool {
        let lower = name.lowercased()
        let hex = hex.lowercased()
        let npub = npub.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.count == 64, hex.allSatisfy(\.isHexDigit), lower.contains(hex) { return true }
        if npub.hasPrefix("npub1"), npub.count >= 60, lower.contains(npub) { return true }
        return false
    }
}
