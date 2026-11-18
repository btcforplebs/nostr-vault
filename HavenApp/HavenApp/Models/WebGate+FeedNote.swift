import Foundation

extension WebGate.Subject {
    /// A feed row for the gate. It covers everything
    /// `FeedFilterEngine.involvesBlocked` and `MuteList.hides(FeedNote)`
    /// checked on their own before the gate:
    /// - An embedded repost (FeedNote swapped in the original) is signed by
    ///   `repostedBy`, and its original author is related.
    /// - A bare repost (empty content, `pubkey` is the reposter) is related to
    ///   the original's author, looked up or taken from its `p` tag.
    /// - A reply is related to its parent's author once that note has loaded.
    ///
    /// - Parameter authorOf: the author of a referenced event id, or nil when
    ///   that event has not loaded.
    static func feed(_ note: FeedNote, authorOf: (String) -> String? = { _ in nil }) -> WebGate.Subject {
        var subject = WebGate.Subject.note(
            id: note.id, author: note.pubkey, content: note.content, tags: note.tags,
            parentId: note.parentEventId, repostedBy: note.repostedBy, originalId: note.repostedEventId,
            parentAuthor: note.parentEventId.flatMap(authorOf))
        if note.kind == 6, let originalId = note.repostedEventId,
           let original = authorOf(originalId) ?? note.tags.first(where: { $0.count >= 2 && $0[0] == "p" })?[1],
           !subject.related.contains(original) {
            subject.related.append(original)
        }
        return subject
    }
}

extension FeedNote {
    /// Whether this note `p`-tags `owner`: a reply to them, or a mention.
    func isAddressed(to owner: String) -> Bool {
        guard !owner.isEmpty else { return false }
        let key = owner.lowercased()
        return tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1].lowercased() == key }
    }
}
