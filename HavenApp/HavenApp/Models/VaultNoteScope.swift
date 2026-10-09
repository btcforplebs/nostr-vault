import Foundation

/// Which kind of post the Vault tab's notes list shows. The relay keeps every
/// kind you publish; the Relay tab used to list articles and highlights mixed
/// into Notes. In the Vault tab each gets its own entry in the mode menu.
enum VaultNoteScope: String, CaseIterable {
    /// Notes, reposts, comments and polls: everything but the two below.
    case notes
    /// Long-form posts (kind 30023). Recipes are articles with a cooking tag.
    case articles
    /// NIP-84 highlights (kind 9802).
    case highlights

    static let articleKind = 30023
    static let highlightKind = 9802
    /// The `t` tags that make an article a recipe (zap.cooking and friends).
    static let recipeTopics: Set<String> = ["zapcooking", "nostrcooking"]

    /// The kinds this scope lists, out of `all` (the relay tab's note kinds).
    /// `split` is false where there is no scope menu (macOS, the old tab), so
    /// Notes keeps showing every kind there.
    func kinds(from all: [Int], split: Bool) -> Set<Int> {
        switch self {
        case .notes:
            guard split else { return Set(all) }
            return Set(all).subtracting([Self.articleKind, Self.highlightKind])
        case .articles: return [Self.articleKind]
        case .highlights: return [Self.highlightKind]
        }
    }

    /// Whether an article's tags mark it as a recipe.
    static func isRecipe(tags: [[String]]) -> Bool {
        tags.contains { $0.count >= 2 && $0[0] == "t" && recipeTopics.contains($0[1].lowercased()) }
    }
}
