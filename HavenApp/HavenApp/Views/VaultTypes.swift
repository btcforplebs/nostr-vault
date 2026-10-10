import SwiftUI

// MARK: - Vault (Notes tab) type definitions
// Extracted from ViewerView for the Vault/Notes tab split.

enum ViewMode {
    /// The Vault tab's first list: everything that came in, newest first.
    case activity
    case notes
    case media
    case likes
    case zaps
    case followers
}

/// Followers from the relay's follower ledger, spam left out: the latest
/// ones, or everyone.
enum FollowersFilter {
    case new
    case all
}

enum ContentFilter {
    case all
    case mine
    case tagged
    case whitelist
    /// Replies to your posts from people outside your Web of Trust. The relay
    /// lets these in (anyone may reply to you); they're kept out of All and
    /// Mentions and listed here instead.
    case outside

    /// Whether a note tagging you comes from outside your network. The one
    /// definition shared by the Notes filter and a notification tap's routing.
    /// An empty graph (not built yet) counts nobody as outside.
    static func isOutside(author: String, owner: String, whitelist: Set<String>, trusted: Set<String>) -> Bool {
        author != owner && !whitelist.contains(author) && !trusted.isEmpty && !trusted.contains(author)
    }
}

/// Likes and Zaps each have two views: what came in on your notes, and what you
/// gave. "On tagged" and "on whitelisted" notes used to be views too; they were
/// the Notes filters again with a heart on, so they're gone.
enum LikesFilter {
    case onMyNotes
    case myLikes
}

enum ZapsFilter {
    case onMyNotes
    case myZaps
}

enum SearchScope: CaseIterable, Equatable {
    case notes
    case profiles
    case hashtags

    var label: String {
        switch self {
        case .notes: return "Notes"
        case .profiles: return "Profiles"
        case .hashtags: return "Hashtags"
        }
    }

    var icon: String {
        switch self {
        case .notes: return "doc.text"
        case .profiles: return "person.2"
        case .hashtags: return "number"
        }
    }
}

struct ParsedZapReceipt {
    let senderPubkey: String
    let targetNoteId: String?
    let amountSats: Int64
    /// The zap request inside the receipt carries a valid signature. Anyone
    /// can publish a receipt naming you as the sender; only a signed request
    /// proves you made the zap.
    let requestIsSigned: Bool
}
