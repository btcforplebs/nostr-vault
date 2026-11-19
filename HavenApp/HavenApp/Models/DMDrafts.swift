import Foundation

/// What you were typing in each chat, kept when you leave it (B9,
/// 2026-11-19): per account and person, in memory only, so a message you
/// never sent is not written to disk. An account switch drops the old
/// account's (A5). A send that fails after you left puts its words back
/// here (B5), for when you open the chat again.
final class DMDrafts {
    static let shared = DMDrafts()

    private var texts: [String: String] = [:]

    static func key(account: String, counterparty: String) -> String {
        "\(account.lowercased())|\(counterparty.lowercased())"
    }

    func text(account: String, counterparty: String) -> String? {
        texts[Self.key(account: account, counterparty: counterparty)]
    }

    /// Blank or whitespace only removes the draft.
    func set(_ text: String, account: String, counterparty: String) {
        let key = Self.key(account: account, counterparty: counterparty)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts[key] = nil
        } else {
            texts[key] = text
        }
    }

    /// Every draft but `account`'s.
    func keepOnly(account: String) {
        let prefix = account.lowercased() + "|"
        texts = texts.filter { $0.key.hasPrefix(prefix) }
    }
}
