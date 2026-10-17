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

    /// True only for something that may be published: never the wallet
    /// string itself, never empty.
    static func isCiphertext(_ content: String) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !content.lowercased().contains("walletconnect")
    }

    /// What the account's slot holds, as far as this device can tell. Only
    /// `empty` says nothing is saved; a slot that exists but was not (or could
    /// not be) read is its own state, so the screen never claims "not saved"
    /// while the secret may still be on the relays.
    enum Status: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        /// No relay answered: can't say either way.
        case unknown
        /// A relay answered and had no wallet, or the wallet was removed.
        /// (One that never answers, such as a Mac relay that is off, can't
        /// keep the screen from deciding.)
        case empty
        case saved(uri: String, savedAt: Int64)
        /// A wallet is saved; reading it needs the signer (bunker or Amber),
        /// which is only asked when the user taps.
        case needsSigner(savedAt: Int64)
        /// A wallet is saved, but this device can't read it (no key, the
        /// signer refused, or it isn't a wallet string).
        case unreadable(savedAt: Int64)

        /// A slot with a wallet in it exists on the account, readable or not.
        var hasSlot: Bool {
            switch self {
            case .saved, .needsSigner, .unreadable: return true
            case .unknown, .empty: return false
            }
        }

        var savedAt: Int64? {
            switch self {
            case .saved(_, let at), .needsSigner(let at), .unreadable(let at): return at
            case .unknown, .empty: return nil
            }
        }

        /// The wallet string is a spending secret: never in a log.
        var description: String {
            switch self {
            case .unknown: return "unknown"
            case .empty: return "empty"
            case .saved(_, let at): return "saved(<redacted>, \(at))"
            case .needsSigner(let at): return "needsSigner(\(at))"
            case .unreadable(let at): return "unreadable(\(at))"
            }
        }
        var debugDescription: String { description }
    }

    /// How far the slot's content was read.
    enum Read {
        /// Not tried: it would ask the signer, and the user hasn't tapped.
        case notTried
        case failed
        case plaintext(String)
    }

    /// The status for a lookup: `slot` is the newest event found (nil when
    /// none), `answeredAny` whether at least one relay answered the request
    /// (EOSE). A refusal such as `CLOSED: auth-required` is not an answer.
    static func status(slot: (content: String, tags: [[String]], createdAt: Int64)?,
                       answeredAny: Bool, read: Read) -> Status {
        guard let slot else { return answeredAny ? .empty : .unknown }
        if isCleared(content: slot.content, tags: slot.tags) { return .empty }
        switch read {
        case .notTried: return .needsSigner(savedAt: slot.createdAt)
        case .failed: return .unreadable(savedAt: slot.createdAt)
        case .plaintext(let text):
            guard let uri = walletString(fromDecrypted: text) else { return .unreadable(savedAt: slot.createdAt) }
            return .saved(uri: uri, savedAt: slot.createdAt)
        }
    }
}
