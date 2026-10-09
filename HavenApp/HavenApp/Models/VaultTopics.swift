import Foundation

/// Topics for the "Fill your vault" guide. They are words, not people: picking
/// one follows a hashtag, and every person the user then follows is their own
/// choice. Android keeps the same lists in `VaultTopics.kt`; change both.
enum VaultTopics {
    /// The 20 shown first.
    static let starter: [String] = [
        "bitcoin", "nostr", "photography", "art", "music",
        "food", "outdoors", "tech", "gaming", "books",
        "fitness", "science", "memes", "travel", "pets",
        "film", "design", "privacy", "farming", "history",
    ]

    /// Behind "More topics", after the starter 20. The user can also type any
    /// hashtag there.
    static let more: [String] = [
        "anime", "astronomy", "beer", "cars", "chess", "coffee",
        "comedy", "cooking", "crypto", "cycling", "dogs", "cats", "economics",
        "education", "environment", "fashion", "fishing", "football",
        "gardening", "health", "hiking", "homestead", "jazz", "lightning",
        "linux", "mathematics", "meditation", "motorcycles", "nature",
        "news", "opensource", "parenting", "philosophy", "plebchain",
        "podcasts", "poetry", "programming", "running", "selfhosting",
        "skateboarding", "space", "sports", "surfing", "writing", "zap",
    ].filter { !starter.contains($0) }

    /// Turns what someone typed into a hashtag: no leading #, lowercase
    /// (NIP-24), no spaces. Nil when nothing usable is left.
    static func normalize(_ typed: String) -> String? {
        var tag = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.lowercased().filter { !$0.isWhitespace }
        return tag.isEmpty ? nil : tag
    }
}
