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

/// The "Vault" list's filters: everything, or only what you might answer.
enum ActivityFilter {
    case all
    /// Replies, mentions and quotes.
    case mentions

    func includes(_ kind: VaultActivity.Kind) -> Bool {
        switch self {
        case .all: return true
        case .mentions: return kind == .reply || kind == .mention || kind == .quote
        }
    }
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

/// One filter in the Vault tab's right pill, for the note its tap leaves.
enum VaultFilterChoice: Equatable {
    case activity(ActivityFilter)
    case notes(ContentFilter)
    case recipes
    case likes(LikesFilter)
    case zaps(ZapsFilter)
    case followers(FollowersFilter)

    var icon: String {
        switch self {
        case .activity(.all), .notes(.all), .notes(.whitelist): return "square.stack"
        case .activity(.mentions), .notes(.tagged): return "at"
        case .notes(.mine): return "person.fill"
        case .notes(.outside): return "person.crop.circle.badge.questionmark"
        case .recipes: return "fork.knife"
        case .likes(.onMyNotes), .zaps(.onMyNotes): return "tray.and.arrow.down.fill"
        case .likes(.myLikes), .zaps(.myZaps): return "tray.and.arrow.up.fill"
        case .followers(.new): return "sparkles"
        case .followers(.all): return "person.3.fill"
        }
    }

    /// Notes, Likes and Zaps rebuild their list off the main thread after a
    /// pick; the note waits for it so its count is the new list's.
    var waitsForList: Bool {
        switch self {
        case .notes, .recipes, .likes, .zaps: return true
        case .activity, .followers: return false
        }
    }

    /// What the note calls the picked list: "Mentions", "Your articles".
    func name(scope: VaultNoteScope) -> String {
        let things = scope.rawValue
        switch self {
        case .activity(.all): return "Everything"
        case .activity(.mentions), .notes(.tagged): return "Mentions"
        case .notes(.all), .notes(.whitelist): return "All \(things)"
        case .notes(.mine): return "Your \(things)"
        case .notes(.outside): return "From outside your network"
        case .recipes: return "Recipes"
        case .likes(.onMyNotes): return "Likes received"
        case .likes(.myLikes): return "Likes given"
        case .zaps(.onMyNotes): return "Zaps received"
        case .zaps(.myZaps): return "Zaps given"
        case .followers(.new): return "Newest followers"
        case .followers(.all): return "All followers"
        }
    }

    /// The note for an empty list; never "· 0".
    func emptyText(scope: VaultNoteScope) -> String {
        let things = scope.rawValue
        switch self {
        case .activity(.all): return "Nothing new yet"
        case .activity(.mentions), .notes(.tagged): return "No mentions yet"
        case .notes(.all), .notes(.whitelist): return "No \(things) yet"
        case .notes(.mine): return "None of your \(things) yet"
        case .notes(.outside): return "No replies from outside"
        case .recipes: return "No recipes yet"
        case .likes(.onMyNotes): return "No likes yet"
        case .likes(.myLikes): return "No likes given yet"
        case .zaps(.onMyNotes): return "No zaps yet"
        case .zaps(.myZaps): return "No zaps given yet"
        case .followers(.new), .followers(.all): return "No followers yet"
        }
    }
}
