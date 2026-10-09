import Foundation

/// NIP-57 zap receipt spoofing guard.
///
/// A kind 9735 zap receipt is just a normal Nostr event — anyone can publish one
/// claiming any amount, pointing at any note/profile, on any relay. The only thing
/// that makes a receipt trustworthy is that it was published by the pubkey the
/// recipient's own LNURL endpoint designates (`nostrPubkey` in the LNURL pay
/// response) as the one authorized to publish receipts on their behalf. Without
/// checking that, every zap total/notification in the app is spoofable by anyone
/// who can reach a relay it queries.
@MainActor
enum ZapValidationService {
    /// recipientPubkey -> that recipient's authorized zap-receipt publisher, or nil
    /// if it couldn't be determined (no lud16, resolution failed, or the provider
    /// doesn't advertise one). Cached for the app session since this rarely changes.
    private static var authorizedPublisherCache: [String: String?] = [:]

    /// Whether `receipt` (a kind 9735 event) should be trusted as a real zap on
    /// `recipientPubkey`'s behalf.
    ///
    /// Fails open when we can't determine the recipient's authorized publisher
    /// (missing lud16, network error, or a provider that simply doesn't advertise
    /// `nostrPubkey`) — that's the same trust level the app has always had, not a
    /// regression. It only fails a receipt when we positively know who *should*
    /// have published it and this one didn't come from them.
    static func isValidReceipt(pubkey receiptPubkey: String, recipientPubkey: String) async -> Bool {
        guard let authorized = await resolveAuthorizedPublisher(for: recipientPubkey) else {
            return true
        }
        return receiptPubkey.lowercased() == authorized.lowercased()
    }

    /// The pubkey `recipientPubkey`'s LNURL service names as its zap-receipt
    /// publisher, or nil when that can't be determined. For callers that
    /// must fail closed, unlike `isValidReceipt`.
    static func authorizedPublisher(for recipientPubkey: String) async -> String? {
        await resolveAuthorizedPublisher(for: recipientPubkey)
    }

    private static func resolveAuthorizedPublisher(for recipientPubkey: String) async -> String? {
        if let cached = authorizedPublisherCache[recipientPubkey] {
            return cached
        }

        // No profile yet is not an answer: caching nil here would leave this
        // recipient unresolved for the whole session once it loads.
        guard let profile = NostrService.shared.profiles[recipientPubkey] else { return nil }
        let resolved: String?
        do {
            if let lud16 = profile.lud16, !lud16.isEmpty {
                resolved = try await LNURLService.resolveAddress(lud16).nostrPubkey
            } else if let lud06 = profile.lud06, !lud06.isEmpty {
                resolved = try await LNURLService.resolveRawLNURL(lud06).nostrPubkey
            } else {
                resolved = nil
            }
        } catch {
            resolved = nil
        }

        authorizedPublisherCache[recipientPubkey] = resolved
        return resolved
    }
}
