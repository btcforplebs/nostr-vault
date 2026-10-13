import Foundation

/// The rules for reading a repost (kind 6, or NIP-18's generic kind 16).
/// Pure, so the feed and the tests share one copy.
enum GenericRepost {
    /// NIP-18 generic repost: a repost of anything but a text note.
    static let kind = 16

    /// The kind of the event a repost carries in its content, or nil when
    /// the content is empty or not an event. An embedded event with no
    /// `kind` is read as a text note, as kind 6 always assumed.
    static func embeddedKind(content: String) -> Int? {
        guard !content.isEmpty, let data = content.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              inner["pubkey"] is String else { return nil }
        return inner["kind"] as? Int ?? 1
    }

    /// What a repost points at: its `e` tag, else its `a` coordinate in
    /// `QuoteReference`'s spelling (a repost of an article may carry only
    /// that).
    static func target(tags: [[String]]) -> String? {
        if let id = tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] { return id }
        return tags.first { $0.count >= 2 && $0[0] == "a" }.map { QuoteReference.coordinatePrefix + $0[1] }
    }

    /// The kinds a repost may carry into a timeline: the ones drawn as a
    /// card there (a note, comment, article, poll, picture or highlight).
    /// A repost of anything else (a video, live stream, calendar event)
    /// would show as a bare text body, so it is left out.
    static let shownKinds: Set<Int> = [1, 1111, 30023, 1068, 20, 9802]

    /// Whether a timeline shows this repost: by its `k` tag (NIP-18), else
    /// by the event it embeds, else (bare, untagged) yes, as kind 6 always has.
    static func isShown(tags: [[String]], content: String) -> Bool {
        if let k = tags.first(where: { $0.count >= 2 && $0[0] == "k" }).flatMap({ Int($0[1]) }) {
            return shownKinds.contains(k)
        }
        if let embedded = embeddedKind(content: content) { return shownKinds.contains(embedded) }
        return true
    }
}
