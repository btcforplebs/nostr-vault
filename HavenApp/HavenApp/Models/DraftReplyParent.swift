import Foundation

/// What a saved reply draft knows about the note it answers, from the draft's
/// own saved tags, so the drafts list and the composer can name the parent
/// before (or without) loading it. Pure, so MediaLogicTests checks it.
/// Android twin: `DraftReplyParent.kt`.
enum DraftReplyParent {
    /// The parent's author. `DraftService.saveDraftLocally` writes the
    /// parent's `p` tag before any other `p`, so the first one is theirs.
    static func parentPubkey(replyToId: String?, tags: [[String]]) -> String? {
        guard replyToId != nil else { return nil }
        return tags.first { $0.count >= 2 && $0[0] == "p" && !$0[1].isEmpty }?[1]
    }

    /// Tags for a stand-in parent that make posting build the same reply
    /// tags the real parent would: the thread root when the parent was
    /// itself a reply, and the other people in the thread.
    static func standInTags(replyToId: String, rootId: String?, parentPubkey: String, tags: [[String]]) -> [[String]] {
        var out: [[String]] = []
        if let root = rootId, !root.isEmpty, root != replyToId { out.append(["e", root, "", "root"]) }
        var seen: Set<String> = [parentPubkey]
        for tag in tags where tag.count >= 2 && tag[0] == "p" && seen.insert(tag[1]).inserted {
            out.append(["p", tag[1]])
        }
        return out
    }

    /// The drafts list's line under the Reply chip: "↩ name: first line of
    /// their note", or "↩ Reply to name" while the note isn't loaded.
    static func line(name: String, parentContent: String?) -> String {
        let first = (parentContent ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let first else { return "↩ Reply to \(name)" }
        return "↩ \(name): \(first)"
    }
}
