import Foundation

extension NpubValidation {
    /// What someone typed or pasted as an account to add or block: the
    /// lowercase `npub1…` when it is a real one (an optional `nostr:` prefix
    /// and surrounding space allowed), or nil. A cut-off or mistyped npub
    /// used to pass a bare "starts with npub" check.
    static func typedNpub(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        guard hexPubkey(fromNpub: text) != nil else { return nil }
        return text.lowercased()
    }
}
