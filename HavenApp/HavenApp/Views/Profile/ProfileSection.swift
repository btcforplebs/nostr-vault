import SwiftUI

/// A profile's tabs. The five every profile has come first; the ones that only
/// show once this person's articles, diVines, music or listings arrive go after
/// them, so a late tab never pushes an earlier one along.
enum ProfileSection: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case media = "Media"
    case replies = "Replies"
    case reposts = "Reposts"
    case tagged = "Tagged"
    case articles = "Articles"
    case divines = "diVines"
    case music = "Music"
    case shop = "Shop"
    var id: String { rawValue }

    /// The feed types' own icons, so a tab reads the same as the feed it
    /// matches. Tabs are icons only; the name is the accessibility label
    /// and, on the Mac, the tooltip.
    var symbol: String {
        switch self {
        case .notes: return "text.bubble"
        case .media: return FeedMode.media.symbolName
        case .replies: return "arrowshape.turn.up.left"
        case .reposts: return "arrow.2.squarepath"
        case .articles: return FeedMode.articles.symbolName
        case .divines: return FeedMode.reels.symbolName
        case .music: return FeedMode.music.symbolName
        case .tagged: return "at"
        case .shop: return FeedMode.marketplace.symbolName
        }
    }

    /// The tabs filled from the profile's own note stream.
    var isNoteTab: Bool {
        switch self {
        case .notes, .media, .replies, .reposts, .tagged: return true
        default: return false
        }
    }
}
