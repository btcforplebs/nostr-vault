import Foundation

extension NIP10Thread {
    /// The tags and kind of a reply to a parent note: NIP-10 e/p tags (root
    /// and reply markers) on a kind 1 reply, or a NIP-22 comment (kind 1111)
    /// for a parent that is not a note. One definition for the post and the
    /// composer's preview, so the preview shows a reply as the post will be.
    /// The parent is the note actually answered (a repost already resolved to
    /// the note it carries).
    static func replyTags(parentId: String, parentPubkey: String, parentTags: [[String]], parentKind: Int,
                          relayHint: String) -> (tags: [[String]], kind: Int) {
        var tags: [[String]] = []

        // NIP-10: Determine the thread root from the parent's e-tags
        let parentETags = parentTags.filter { $0.count >= 2 && $0[0] == "e" }
        let parentNonMentionETags = parentETags.filter { tag in
            guard tag.count >= 4 else { return true }
            return tag[3] != "mention"
        }

        let parentNonMentionATags = parentTags.filter { tag in
            guard tag.count >= 2 && tag[0] == "a" else { return false }
            guard tag.count >= 4 else { return true }
            return tag[3] != "mention"
        }

        // Automatic (Logen, 2026-10-03): a note gets a kind 1 reply,
        // anything else a NIP-22 comment. No switch to explain.
        let eventKind = replyKind(parentKind: parentKind)
        if eventKind == commentKind {
            // NIP-22: on a comment, copy its root and point at it; on
            // anything else the parent is the root (E, or A alone for
            // addressables and replaceables).
            tags.append(contentsOf: commentTags(
                parentId: parentId, parentKind: parentKind,
                parentPubkey: parentPubkey, parentTags: parentTags,
                relayHint: relayHint
            ))
        } else if parentNonMentionETags.isEmpty {
            // Parent IS the root note — single e-tag with "root" marker.
            // NIP-10: the optional 5th element is the event author's pubkey,
            // used by the outbox model to know whose relays to fetch it from.
            tags.append(["e", parentId, relayHint, "root", parentPubkey])
        } else {
            // Parent is itself a reply — find the thread root
            let threadRootId: String
            let threadRootPubkey: String?
            if let rootTag = parentNonMentionETags.first(where: { $0.count >= 4 && $0[3] == "root" }) {
                // Preferred: explicit "root" marker in parent's tags
                threadRootId = rootTag[1]
                threadRootPubkey = rootTag.count >= 5 ? rootTag[4] : nil
            } else {
                // Deprecated positional: first e-tag is the root
                threadRootId = parentNonMentionETags[0][1]
                threadRootPubkey = parentNonMentionETags[0].count >= 5 ? parentNonMentionETags[0][4] : nil
            }
            if let pk = threadRootPubkey {
                tags.append(["e", threadRootId, relayHint, "root", pk])
            } else {
                tags.append(["e", threadRootId, relayHint, "root"])
            }
            tags.append(["e", parentId, relayHint, "reply", parentPubkey])

            // A legacy thread under an addressable root carries its
            // coordinate forward. a/A tags have no marker field.
            if let rootATag = parentNonMentionATags.first(where: { $0.count >= 4 && $0[3] == "root" }) ?? parentNonMentionATags.first {
                tags.append(["a", rootATag[1], relayHint])
            }
        }

        // Always tag the parent author (commentReplyTags already did)
        if eventKind != commentKind {
            tags.append(["p", parentPubkey])
        }

        // NIP-10: Accumulate p-tags from parent (thread participants), deduplicated
        var seenPubkeys = Set<String>([parentPubkey])
        for tag in parentTags where tag.count >= 2 && tag[0] == "p" {
            let pk = tag[1]
            if seenPubkeys.insert(pk).inserted {
                tags.append(["p", pk])
            }
        }
        return (tags, eventKind)
    }
}
