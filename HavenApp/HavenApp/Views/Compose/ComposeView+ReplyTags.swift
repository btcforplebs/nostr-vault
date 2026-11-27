import Foundation

extension ComposeView {
    /// The reply tags and kind for the note being answered, or none and kind 1
    /// for a new note. Shared by Post and the preview (NIP10Thread.replyTags).
    func replyTagsAndKind(relayHint: String) -> (tags: [[String]], kind: Int) {
        guard let parent = effectiveReplyTo else { return ([], 1) }
        // NIP-10 tags — for reposts (kind 6), reply to the original note, not the repost
        let effectiveParentId: String
        let effectiveParentPubkey: String
        let effectiveParentTags: [[String]]
        let effectiveParentKind: Int

        if parent.kind == 6, let originalId = parent.repostedEventId {
            effectiveParentId = originalId
            if let original = FeedService.shared.notes.first(where: { $0.id == originalId }) {
                effectiveParentPubkey = original.pubkey
                effectiveParentTags = original.tags
                effectiveParentKind = original.kind
            } else {
                effectiveParentPubkey = parent.pubkey
                effectiveParentTags = parent.tags
                effectiveParentKind = 1
            }
        } else {
            effectiveParentId = parent.id
            effectiveParentPubkey = parent.pubkey
            effectiveParentTags = parent.tags
            effectiveParentKind = parent.kind
        }
        return NIP10Thread.replyTags(parentId: effectiveParentId, parentPubkey: effectiveParentPubkey,
                                     parentTags: effectiveParentTags, parentKind: effectiveParentKind, relayHint: relayHint)
    }
}
