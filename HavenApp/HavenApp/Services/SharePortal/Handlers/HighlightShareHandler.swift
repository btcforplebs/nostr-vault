import SwiftUI

/// Highlight (NIP-84, kind 9802) from a web page or another app's text. The
/// reference action for the Share Portal: queued by the extension, reviewed
/// and published here.
struct HighlightShareHandler: SharePortalHandler {
    let action = NVShareAction.highlight

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(HighlightReviewView(intent: intent, close: close))
    }
}

extension HighlightShareHandler {
    /// The account the highlight posts as: the one picked in the share
    /// sheet, else the one active now.
    static func account(for intent: NVShareIntent) -> String {
        let config = ConfigService.shared.config
        return intent.account ?? PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
    }

    /// Signs with that account's signer and sends. Locked to the account, so
    /// a switch while the signer is busy cannot post it as someone else.
    /// `url`: the shared page, else the Page link typed for a text-only share.
    static func publish(_ intent: NVShareIntent, url: String?, passage: String, comment: String) async throws {
        let npub = account(for: intent)
        guard let hex = Bech32.decode(npub)?.hexString else { throw ModePostPublisher.PublishError.signing }
        let tags = HighlightShareTags.tags(url: url, passage: passage, comment: comment)
        _ = try await ModePostPublisher.publish(kind: HighlightShareTags.kind,
                                                content: passage.trimmingCharacters(in: .whitespacesAndNewlines),
                                                tags: tags, nostrService: NostrService.shared,
                                                lockedTo: PostingAccount.Lock(npub: npub, hex: hex))
    }
}
