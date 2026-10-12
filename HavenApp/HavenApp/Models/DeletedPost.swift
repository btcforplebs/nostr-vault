import Foundation

/// A copy of one of your own posts, saved on this device just before its
/// NIP-09 delete request (kind 5) went out.
///
/// Nostr has no real undo: once the kind 5 is out, relays that honour it —
/// your own vault included — refuse the original event id for good. So
/// un-delete publishes the saved text and tags again as a *new* event. It gets
/// a new id and today's time, and the likes and replies on the old id stay
/// with the old id.
struct DeletedPost: Codable, Identifiable, Equatable {
    /// The deleted event, exactly as it was signed.
    let id: String
    let pubkey: String
    let createdAt: Int64
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String
    /// When the delete was sent from this device.
    let deletedAt: Date

    /// Words the Recently Deleted screen shows next to Un-delete.
    static let undeleteNote = "Un-delete posts it again as a new post. Likes and replies on the old post don't come back."

    /// What un-delete signs: the same kind, text and tags, so a deleted reply
    /// comes back as a reply in the same thread. `created_at` is not carried
    /// over: the signer stamps the moment of un-delete.
    ///
    /// Two tags are dropped. `nonce` claims proof of work for the *old* event
    /// id, which the new id does not have; the signer mines a fresh one when
    /// proof of work is on. `expiration` (NIP-40) may already have passed,
    /// and relays refuse or drop an event that is already expired.
    func republishDraft() -> (kind: Int, content: String, tags: [[String]]) {
        (kind, content, tags.filter { !Self.droppedTags.contains($0.first ?? "") })
    }

    private static let droppedTags: Set<String> = ["nonce", "expiration"]

    /// Whether a deleted event of `kind` gets a copy. Replaceable and
    /// addressable kinds (0, 3, 10000–19999, 30000–39999) do not: posted again
    /// with today's time, an old version would replace whatever newer version
    /// is live at that address.
    static func keepsCopy(kind: Int) -> Bool {
        !(kind == 0 || kind == 3 || (10000..<20000).contains(kind) || (30000..<40000).contains(kind))
    }

    /// The copy to save once the delete request is signed: `copy` only if the
    /// kind 5 came from the same key, so a delete signed under another account
    /// (switched mid-delete) leaves no copy of a post still live.
    static func keptAfterSigning(_ copy: DeletedPost?, signer: String) -> DeletedPost? {
        guard let copy, copy.pubkey == signer else { return nil }
        return copy
    }
}
