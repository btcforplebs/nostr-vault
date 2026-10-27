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
        /// Set for a NIP-30 custom emoji; `emoji` is then its `:shortcode:`.
        var custom: CustomEmoji? = nil
        var count: Int { reactorPubkeys.count }
        /// One per emoji, and per image for a custom one (ForEach id).
        var key: String { custom.map { "\(emoji)|\($0.url)" } ?? emoji }
    }

    /// The emoji a reaction shows: "+" and an empty content are a like.
    static func emoji(for content: String) -> String {
        (content == "+" || content.isEmpty) ? "❤️" : content
    }

    /// Reactions without their tags, so custom emoji are skipped.
    static func groups(_ reactions: [(content: String, pubkey: String, createdAt: Int64)]) -> [Group] {
        groups(tagged: reactions.map { (content: $0.content, pubkey: $0.pubkey, createdAt: $0.createdAt, tags: []) })
    }

    /// Most reactions first. A tie goes to the emoji used first, then to the
    /// emoji's own text, so the same reactions always give the same order.
    /// A custom emoji whose tag gives its image is a group per shortcode and
    /// image. Other contents longer than four characters (a `:shortcode:`
    /// with no tag, stray text) are skipped.
    static func groups(tagged reactions: [(content: String, pubkey: String, createdAt: Int64, tags: [[String]])]) -> [Group] {
        var pubkeys: [String: [String]] = [:]
        var firstSeen: [String: Int64] = [:]
        var display: [String: (emoji: String, custom: CustomEmoji?)] = [:]
        for rx in reactions {
            let key: String
            if let custom = CustomEmoji.forReaction(content: rx.content, tags: rx.tags) {
                key = "\(custom.content)|\(custom.url)"
                if display[key] == nil { display[key] = (custom.content, custom) }
            } else {
                let emoji = emoji(for: rx.content)
                guard emoji.count <= 4 else { continue }
                key = emoji
                if display[key] == nil { display[key] = (emoji, nil) }
            }
            pubkeys[key, default: []].append(rx.pubkey)
            firstSeen[key] = min(firstSeen[key] ?? rx.createdAt, rx.createdAt)
        }
        return pubkeys
            .map { key, reactors in
                Group(emoji: display[key]?.emoji ?? key, reactorPubkeys: reactors, custom: display[key]?.custom)
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                let fa = firstSeen[a.key] ?? 0, fb = firstSeen[b.key] ?? 0
                if fa != fb { return fa < fb }
                return a.key < b.key
            }
    }
}
