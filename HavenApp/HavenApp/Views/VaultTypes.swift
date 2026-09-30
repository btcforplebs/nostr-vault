import SwiftUI

// MARK: - Vault (Notes tab) type definitions
// Extracted from ViewerView for the Vault/Notes tab split.

enum ViewMode {
    case notes
    case media
    case likes
    case zaps
}

enum ContentFilter {
    case all
    case mine
    case tagged
    case whitelist
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
}
