import Foundation

/// The wallet connection (NWC string) kept on the user's own Nostr account, so
/// another device or another app signed in with the same key can use it.
///
/// One NIP-78 app-data event (kind 30078) in Wisp's format, so the two apps
/// read each other's: `d` = `nwc-wallet-backup`, content = the raw
/// `nostr+walletconnect://` string NIP-44 encrypted to the account's own key.
/// Wisp marks nothing as removed; an empty content (and our `deleted` tag)
/// means the saved wallet was taken off. Android twin: `NwcBackup`.
enum NWCBackup {
    static let kind = 30078
    static let dTag = "nwc-wallet-backup"
    private static let scheme = "nostr+walletconnect://"

    /// Tags of a saved wallet. The content goes in already encrypted.
    static let tags: [[String]] = [
        ["d", dTag],
        ["client", "Nostr Vault"],
        ["encryption", "nip44"],
    ]

    /// Tags of the event that takes the saved wallet off (empty content).
    static let clearedTags: [[String]] = [
        ["d", dTag],
        ["deleted", "true"],
    ]

    /// Whether an event is this account's saved-wallet slot.
    static func isBackup(kind: Int, tags: [[String]]) -> Bool {
        kind == self.kind && tags.contains { $0.count >= 2 && $0[0] == "d" && $0[1] == dTag }
    }

    /// Whether the slot holds no wallet: empty content, or marked deleted.
    static func isCleared(content: String, tags: [[String]]) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || tags.contains { $0.count >= 2 && $0[0] == "deleted" && $0[1] == "true" }
    }

    /// The wallet string in a decrypted slot, or nil when it is not one.
    /// Same rule as Wisp's `decryptNwcBackup`: trimmed, and it must start
    /// with `nostr+walletconnect://` in any case.
    static func walletString(fromDecrypted plaintext: String) -> String? {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix(scheme) ? trimmed : nil
    }

    /// The string that goes into the encrypted content: trimmed, as Wisp
    /// writes it. Nil for anything that is not a wallet string.
    static func plaintext(forSaving uri: String) -> String? {
        walletString(fromDecrypted: uri)
    }
}
