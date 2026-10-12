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
    /// A `nonce` tag is dropped. It claims proof of work for the *old* event
    /// id, which the new id does not have; the signer mines a fresh one when
    /// proof of work is on.
    func republishDraft() -> (kind: Int, content: String, tags: [[String]]) {
        (kind, content, tags.filter { $0.first != "nonce" })
    }
}
