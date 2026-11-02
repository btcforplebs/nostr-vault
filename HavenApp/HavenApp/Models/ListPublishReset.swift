import Foundation

/// What this device remembers about the lists it published, wiped by a
/// factory reset. Kept, it outlived the reset: signed back in with the same
/// key, the media server list (10063) and blocked relays (10006) still
/// counted the entries published before as "managed here", the reset config
/// no longer had them, so the next edit removed them from the published
/// list. The interest cache and the fresh-key mark went the same way
/// (list-wipe audit 2026-11-02). With these gone, the next edit starts from
/// the copy on the network. Twin of Android's ConfigStore.resetApp list state.
enum ListPublishReset {
    /// Per-account UserDefaults keys, by prefix (`<prefix><hex>`).
    static let defaultsPrefixes = ["serverListManaged.", "interestList."]
    /// Whole UserDefaults keys.
    static let defaultsKeys = ["freshAccountKeys"]

    static func clear(defaults: UserDefaults = .standard, basesFile: URL = ListMerge.Bases.sharedFile) {
        for key in defaults.dictionaryRepresentation().keys
            where defaultsKeys.contains(key) || defaultsPrefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        try? FileManager.default.removeItem(at: basesFile)
    }
}
