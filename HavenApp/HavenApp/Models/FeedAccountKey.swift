import Foundation

/// The key the feed's per-account files and caches are named by: the active
/// account's npub, else the main account's npub, and "" while there is no
/// account (setup, or just after a factory reset). Nothing is saved under "".
///
/// Before this the main account was keyed "owner" whatever its npub, so
/// `feed_snapshot_owner.json` and `following_snapshots_owner.json` outlived
/// a factory reset and the next account set up here loaded the old
/// account's follow list from them (Logen, 3.2.0 (11), 2026-11-06).
///
/// Pure Foundation so MediaLogicTests can test it.
enum FeedAccountKey {
    static func key(activeNpub: String, ownerNpub: String) -> String {
        let active = activeNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty { return active }
        return ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The files the main account's feed was saved in under the old "owner"
    /// key. They name no account, so they are deleted, never handed to the
    /// account that is set up now.
    static let legacyOwnerFiles = [
        "feed_snapshot_owner.json",
        "following_snapshots_owner.json",
        "interaction_state_owner.json",
    ]

    static func removeLegacyOwnerFiles(in havenDir: URL, fileManager fm: FileManager = .default) {
        for name in legacyOwnerFiles {
            try? fm.removeItem(at: havenDir.appendingPathComponent(name))
        }
    }
}
