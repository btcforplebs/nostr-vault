import Foundation

/// Groups kind-7 reactions into emoji pills for the note detail view.
///
/// The order must depend only on the reactions, never on hash order. Grouping
/// through a `Dictionary` and sorting by count alone left tied emojis in the
/// dictionary's order, which changes on every rebuild, so the pills swapped
/// places each time the view redrew.
enum ReactionGrouping {
    struct Group: Equatable {
        let emoji: String
        let reactorPubkeys: [String]
        var count: Int { reactorPubkeys.count }
    }

    /// The emoji a reaction shows: "+" and an empty content are a like.
    static func emoji(for content: String) -> String {
        (content == "+" || content.isEmpty) ? "❤️" : content
    }

    /// Most reactions first. A tie goes to the emoji used first, then to the
    /// emoji's own text, so the same reactions always give the same order.
    /// Contents longer than four characters (custom `:shortcode:` emoji, stray
    /// text) are skipped.
    static func groups(_ reactions: [(content: String, pubkey: String, createdAt: Int64)]) -> [Group] {
        var pubkeys: [String: [String]] = [:]
        var firstSeen: [String: Int64] = [:]
        for rx in reactions {
            let emoji = emoji(for: rx.content)
            guard emoji.count <= 4 else { continue }
            pubkeys[emoji, default: []].append(rx.pubkey)
            firstSeen[emoji] = min(firstSeen[emoji] ?? rx.createdAt, rx.createdAt)
        }
        return pubkeys
            .map { Group(emoji: $0.key, reactorPubkeys: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let fa = firstSeen[a.emoji] ?? 0, fb = firstSeen[b.emoji] ?? 0
                if fa != fb { return fa < fb }
                return a.emoji < b.emoji
            }
    }
}
