import Foundation

/// The trust card's second button on a profile's or a post's globe, next to
/// "Open in WoT": the person on the web (Brainstorm), where their trust can be
/// checked off this device. Android's TrustCard.kt shows the same pair.
///
/// Kept free of app types so `MediaLogicTests` can compile it.
struct TrustCardWebButton: Equatable {
    let title: String
    /// What a narrow phone shows when `title` doesn't fit.
    let short: String
    let url: URL

    /// Nil when the key can't make a link (not 64 hex characters).
    static func forPerson(_ pubkey: String) -> TrustCardWebButton? {
        guard let link = NostrWebLink.profile(pubkey: pubkey) else { return nil }
        return TrustCardWebButton(title: "Open in \(link.siteName)", short: link.siteName, url: link.url)
    }
}
