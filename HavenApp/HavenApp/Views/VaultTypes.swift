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
    /// The account's kind 10003 (BookmarksView), Logen 2026-11-03.
    case bookmarks
    case followers
    /// The inbox (DMInboxView), a Vault page of its own, Logen 2026-11-03.
    case messages
}

extension ViewMode {
    /// This page for the account row's rules (VaultAccountChips).
    var accountPage: VaultAccountPage {
        switch self {
        case .activity: return .activity
        case .notes: return .notes
        case .media: return .media
        case .likes: return .likes
        case .zaps: return .zaps
        case .bookmarks: return .bookmarks
        case .followers: return .followers
        case .messages: return .messages
        }
    }
}

/// The "Vault" list's filters: everything, only what you might answer, or
/// what tagged you from outside your web (Logen 11-04: the Notes "?" filter
/// moved here, into the pill's ··· menu; All lists none of it).
enum ActivityFilter {
    case all
    /// Replies, mentions and quotes.
    case mentions
    /// Posts that tag you, and likes and reposts, from people outside your
    /// Web of Trust: the lines All leaves out (likes and reposts since Logen's
    /// 2026-11-13 "go all"; All counts them on one "N from outside your web"
    /// line that opens this). Built with `VaultActivity.build(outsideOnly:)`.
    case outside

    func includes(_ kind: VaultActivity.Kind) -> Bool {
        switch self {
        case .all: return true
        case .mentions: return kind == .reply || kind == .mention || kind == .quote
        case .outside: return kind == .reply || kind == .mention || kind == .quote || kind == .article || kind == .highlight
            || kind == .reaction || kind == .repost
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
    /// Fails closed like Android and the web: with no graph yet, everyone but
    /// you, your accounts and your follows (`TrustMap.web`) is outside.
    static func isOutside(author: String, owner: String, whitelist: Set<String>, trusted: Set<String>) -> Bool {
        author != owner && !whitelist.contains(author) && !trusted.contains(author)
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
        case .notes(.outside), .activity(.outside): return "person.crop.circle.badge.questionmark"
        case .recipes: return "fork.knife"
        case .likes(.onMyNotes), .zaps(.onMyNotes): return "tray.and.arrow.down.fill"
        case .likes(.myLikes), .zaps(.myZaps): return "tray.and.arrow.up.fill"
        case .followers(.inWeb): return "person.3.fill"
        case .followers(.outside): return "person.crop.circle.badge.questionmark"
        }
    }

    /// Every list but Followers is rebuilt off the main thread after a pick;
    /// the note waits for it so its count is the new list's.
    var waitsForList: Bool {
        switch self {
        case .activity, .notes, .recipes, .likes, .zaps: return true
        case .followers: return false
        }
    }

    /// What the note calls the picked list: "Mentions", "Your articles".
    func name(scope: VaultNoteScope) -> String {
        let things = scope.rawValue
        switch self {
        case .activity(.all): return "Everything"
        case .activity(.mentions), .notes(.tagged): return "Mentions"
        case .notes(.all): return "All \(things)"
        case .notes(.whitelist): return "Whitelisted"
        case .notes(.mine): return "Your \(things)"
        case .notes(.outside), .activity(.outside): return "Outside your web"
        case .recipes: return "Recipes only"
        case .likes(.onMyNotes): return "Likes received"
        case .likes(.myLikes): return "Likes given"
        case .zaps(.onMyNotes): return "Zaps received"
        case .zaps(.myZaps): return "Zaps given"
        case .followers(.inWeb): return "Followers in your web"
        case .followers(.outside): return "Outside your web"
        }
    }
}
