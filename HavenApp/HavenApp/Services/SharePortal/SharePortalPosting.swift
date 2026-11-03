import Foundation

/// Signing and sending for the Share Portal's review cards: locked to the
/// account the share named (or the active one), so a switch while the
/// signer is busy cannot post as someone else.
@MainActor
enum SharePortalPosting {
    static func account(for intent: NVShareIntent) -> String {
        let config = ConfigService.shared.config
        return intent.account ?? PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
    }

    static func accountHex(for intent: NVShareIntent) -> String? {
        Bech32.decode(account(for: intent))?.hexString
    }

    @discardableResult
    static func publish(kind: Int, content: String, tags: [[String]], for intent: NVShareIntent) async throws -> NostrEvent {
        let npub = account(for: intent)
        guard let hex = Bech32.decode(npub)?.hexString else { throw ModePostPublisher.PublishError.signing }
        return try await ModePostPublisher.publish(kind: kind, content: content, tags: tags,
                                                   nostrService: NostrService.shared,
                                                   lockedTo: PostingAccount.Lock(npub: npub, hex: hex))
    }

    /// Saves a composer draft for the share's account. Nothing is published.
    static func saveDraft(_ draft: ComposerDraft, for intent: NVShareIntent) -> Bool {
        guard let hex = accountHex(for: intent) else { return false }
        var stamped = draft
        stamped.updatedAt = Date()
        ComposerDraftStore.shared.save(stamped, cover: nil, account: hex)
        return ComposerDraftStore.shared.draft(id: stamped.id, account: hex) != nil
    }
}
