import SwiftUI

struct ComposeContext: Identifiable {
    let id = UUID()
    let replyTo: FeedNote?
    let quoteTo: FeedNote?
    var initialContent: String = ""
    var draftId: String? = nil
}

/// A composer for a feed that shows something other than notes.
enum ModeComposer: String, Identifiable {
    case divine, article, recipe, listing

    var id: String { rawValue }

    init?(feedMode: FeedMode) {
        switch feedMode {
        case .reels: self = .divine
        case .articles: self = .article
        case .recipes: self = .recipe
        case .marketplace: self = .listing
        default: return nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .divine: return "diVine"
        case .article: return "Write"
        case .recipe: return "Recipe"
        case .listing: return "Sell"
        }
    }

    var symbolName: String {
        switch self {
        case .divine: return "video.badge.plus"
        case .article: return "doc.richtext"
        case .recipe: return "fork.knife"
        case .listing: return "tag"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .divine: return "Post a diVine"
        case .article: return "Write an article"
        case .recipe: return "Post a recipe"
        case .listing: return "Sell something"
        }
    }
}

enum NoteLayoutMode {
    case sideBySide
    case wide
}


// MARK: - FeedActions Environment Key

/// Closures for all mutation actions FeedNoteRow needs. Passed via @Environment
/// so FeedNoteRow has zero ObservableObject subscriptions — the single biggest
/// win for 120fps scrolling.
struct FeedActions {
    // Like / React
    var likeNote: (FeedNote) -> Void = { _ in }
    var unlikeNote: (FeedNote) -> Void = { _ in }
    var reactToNote: (FeedNote, String) -> Void = { _, _ in }

    // Repost
    var repostNote: (FeedNote) -> Void = { _ in }

    // Zap
    /// Returns whether the payment actually went out, so a caller can gate
    /// tap-confirmation UI (the pulse) on a real send rather than the tap alone.
    var zapNote: (FeedNote, String, Int?) async -> Bool = { _, _, _ in false }
    var getLightningAddress: (String) -> String? = { _ in nil }

    // Delete
    var deleteNote: (String) -> Void = { _ in }

    // Missing content fetching
    var fetchMissingNote: (String) -> Void = { _ in }
    /// Same as `fetchMissingNote`, but bypasses the 30s retry throttle — for a
    /// user-initiated Retry tap, not the automatic on-appear fetch.
    var retryMissingNote: (String) -> Void = { _ in }
    var fetchMissingProfiles: ([String]) -> Void = { _ in }
    var findNote: (String) -> FeedNote? = { _ in nil }

    // User moderation
    var blockUser: (String) -> Void = { _ in }
    var followUser: (String) -> Void = { _ in }
    var unfollowUser: (String) -> Void = { _ in }
    var throttleUser: (String, Int) -> Void = { _, _ in }

    // DM
    var dmUser: (String) -> Void = { _ in }

    // The active user's hex pubkey (for "delete" context menu visibility)
    var activeHexPubkey: String = ""

    /// Leaves `content` as the account's reaction on `note`, replacing any
    /// reaction it already had there (a NIP-09 deletion retracts the old one).
    @MainActor
    private static func react(to note: FeedNote, with content: String,
                              feedService: FeedService, nostrService: NostrService) {
        let noteId = note.id
        let previous = feedService.myReactions[noteId]
        let wasLiked = feedService.likedEventIds.contains(noteId)
        if wasLiked, previous?.content == content { return }
        // A removal still in its undo window becomes final: this is a new reaction.
        UnlikeNotificationManager.shared.commit()
        if let old = previous?.eventId {
            retract(old, feedService: feedService, nostrService: nostrService)
        } else if wasLiked, feedService.pendingReactionTokens[noteId] == nil {
            retractUnknown(on: noteId, feedService: feedService, nostrService: nostrService)
        }

        let token = UUID()
        feedService.pendingReactionTokens[noteId] = token
        feedService.likedEventIds.insert(noteId)
        feedService.myReactions[noteId] = EngagementTracker.MyReaction(content: content, eventId: nil)
        if !wasLiked {
            var stats = feedService.noteStats[noteId] ?? NoteStats()
            stats.reactions += 1
            feedService.noteStats[noteId] = stats
        }
        feedService.saveInteractionState()

        let relayHint = ConfigService.shared.config.nostrURL
        Task {
            let powSnap = PowPreferences.snapshot()
            let powDiff = powSnap.reactionEnabled ? powSnap.reactionDifficulty : 0
            let signed = await nostrService.mineAndSignEventAsync(kind: 7, content: content,
                tags: [["e", noteId, relayHint], ["p", note.pubkey], ["k", String(note.kind)]], difficulty: powDiff)
            await MainActor.run {
                // Changed or removed while signing: this one never goes out.
                guard feedService.pendingReactionTokens[noteId] == token else { return }
                feedService.pendingReactionTokens[noteId] = nil
                guard let signed else {
                    feedService.likedEventIds.remove(noteId)
                    feedService.myReactions[noteId] = nil
                    var s = feedService.noteStats[noteId] ?? NoteStats()
                    s.reactions = max(0, s.reactions - 1)
                    feedService.noteStats[noteId] = s
                    feedService.saveInteractionState()
                    LikeFeedback.failed()
                    return
                }
                nostrService.postEvent(signed)
                feedService.myReactions[noteId] = EngagementTracker.MyReaction(content: content, eventId: signed.id)
                feedService.saveInteractionState()
                LikeFeedback.liked(content)
                feedService.keepLikedNoteLocally(id: noteId)
            }
        }
    }

    /// Clears the account's reaction on `note` at once, with an Undo pill.
    /// When the pill runs out the reaction is deleted on the network.
    @MainActor
    private static func removeReaction(from note: FeedNote,
                                       feedService: FeedService, nostrService: NostrService) {
        let noteId = note.id
        guard feedService.likedEventIds.contains(noteId) else { return }
        let removed = feedService.myReactions[noteId]
        let wasSigning = feedService.pendingReactionTokens.removeValue(forKey: noteId) != nil

        feedService.likedEventIds.remove(noteId)
        feedService.myReactions[noteId] = nil
        // An echo of it arriving during the countdown must not bring it back.
        if let eventId = removed?.eventId { feedService.retractedReactionIds.insert(eventId) }
        var stats = feedService.noteStats[noteId] ?? NoteStats()
        stats.reactions = max(0, stats.reactions - 1)
        feedService.noteStats[noteId] = stats
        feedService.saveInteractionState()

        // Still being signed: dropping the token already stops it going out.
        guard !wasSigning else { return }
        UnlikeNotificationManager.shared.startCountdown(
            onUnlike: {
                if let eventId = removed?.eventId {
                    retract(eventId, feedService: feedService, nostrService: nostrService)
                } else {
                    retractUnknown(on: noteId, feedService: feedService, nostrService: nostrService)
                }
            },
            onUndo: {
                // Reacting again during the countdown commits it first, so
                // Undo only ever restores a note left without a reaction.
                guard !feedService.likedEventIds.contains(noteId) else { return }
                if let eventId = removed?.eventId { feedService.retractedReactionIds.remove(eventId) }
                feedService.likedEventIds.insert(noteId)
                feedService.myReactions[noteId] = removed
                var s = feedService.noteStats[noteId] ?? NoteStats()
                s.reactions += 1
                feedService.noteStats[noteId] = s
                feedService.saveInteractionState()
            }
        )
    }

    /// For a like saved before reactions kept their event id: looks the
    /// account's reactions to the note up on its relays and deletes them,
    /// except one made since (the note's current reaction).
    @MainActor
    private static func retractUnknown(on noteId: String, feedService: FeedService, nostrService: NostrService) {
        Task {
            let ids = await nostrService.fetchOwnReactionIds(to: noteId)
            await MainActor.run {
                let current = feedService.myReactions[noteId]?.eventId
                for id in ids where id != current && !feedService.retractedReactionIds.contains(id) {
                    retract(id, feedService: feedService, nostrService: nostrService)
                }
            }
        }
    }

    /// Publishes a NIP-09 deletion for one of the account's reactions and
    /// remembers it, so relays that keep serving it cannot bring it back.
    @MainActor
    private static func retract(_ reactionId: String, feedService: FeedService, nostrService: NostrService) {
        feedService.retractedReactionIds.insert(reactionId)
        feedService.saveInteractionState()
        Task {
            guard let signed = await nostrService.signEventAsync(
                kind: 5, content: "", tags: [["e", reactionId], ["k", "7"]]) else { return }
            nostrService.postEvent(signed)
        }
    }

    /// Shared factory so FeedView, NoteDetailView, ProfileView, and MenuBarView
    /// don't each duplicate ~70 lines of closure construction.
    @MainActor
    static func make(feedService: FeedService, nostrService: NostrService) -> FeedActions {
        FeedActions(
            likeNote: { note in
                react(to: feedService.originalNote(for: note), with: ConfigService.shared.config.defaultReactionEmoji,
                      feedService: feedService, nostrService: nostrService)
            },
            unlikeNote: { note in
                removeReaction(from: feedService.originalNote(for: note), feedService: feedService, nostrService: nostrService)
            },
            reactToNote: { note, emoji in
                react(to: feedService.originalNote(for: note), with: emoji, feedService: feedService, nostrService: nostrService)
            },
            repostNote: { note in
                PendingPostManager.shared.startRepost(sourceNote: note, nostrService: nostrService)
            },
            zapNote: { note, lud16, amount in
                // A repost is zapped as the note it carries: its id, its author.
                let note = feedService.originalNote(for: note)
                let amountSats = amount ?? (ConfigService.shared.config.defaultZapAmount / 1000)
                do {
                    try await ZapService.shared.zapNote(
                        noteId: note.id,
                        notePubkey: note.pubkey,
                        lud16: lud16,
                        amountSats: amount
                    )
                    await MainActor.run {
                        feedService.zappedEventIds[note.id] = amountSats
                        feedService.saveInteractionState()
                    }
                    return true
                } catch {
                    #if DEBUG
                    print("FeedActions: Zap failed: \(error)")
                    #endif
                    return false
                }
            },
            getLightningAddress: { pubkey in
                if let profile = nostrService.profiles[pubkey] {
                    if let lud06 = profile.lud06, !lud06.isEmpty { return "lnurl:" + lud06 }
                    if let lud16 = profile.lud16, !lud16.isEmpty { return lud16 }
                }
                return nil
            },
            deleteNote: { noteId in
                PendingPostManager.shared.startDelete(
                    noteId: noteId,
                    nostrService: nostrService,
                    feedService: feedService
                )
            },
            fetchMissingNote: { id in feedService.fetchMissingNote(id: id) },
            retryMissingNote: { id in feedService.fetchMissingNote(id: id, force: true) },
            fetchMissingProfiles: { pks in nostrService.fetchMissingProfiles(for: pks) },
            findNote: { id in feedService.findNote(id: id) },
            blockUser: { hexPubkey in
                guard let data = Bech32.hexToData(hexPubkey),
                      let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                ConfigService.shared.blockProfile(npub)
            },
            followUser: { hexPubkey in
                // Same confirmation as following from a profile page.
                let name = nostrService.profiles[hexPubkey]?.bestName ?? "npub…" + String(hexPubkey.suffix(6))
                switch feedService.followUser(hexPubkey) {
                case .success:
                    FollowNotificationManager.shared.add(recipientName: name, kind: .followed)
                case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                    // Queued until the follow list is confirmed; not an error.
                    FollowNotificationManager.shared.addPending(pubkey: hexPubkey, recipientName: name, follow: true)
                case .failure(.alreadyFollowing):
                    break
                case .failure:
                    FollowNotificationManager.shared.add(recipientName: name, kind: .failed("Follow failed"))
                }
            },
            unfollowUser: { hexPubkey in
                let name = nostrService.profiles[hexPubkey]?.bestName ?? "npub…" + String(hexPubkey.suffix(6))
                switch feedService.unfollowUser(hexPubkey) {
                case .success:
                    FollowNotificationManager.shared.add(recipientName: name, kind: .unfollowed)
                case .failure(.contactsNotLoaded), .failure(.listUnavailable):
                    FollowNotificationManager.shared.addPending(pubkey: hexPubkey, recipientName: name, follow: false)
                case .failure(.cannotUnfollowSelf):
                    FollowNotificationManager.shared.add(recipientName: name, kind: .failed("Can't unfollow yourself"))
                case .failure:
                    FollowNotificationManager.shared.add(recipientName: name, kind: .failed("Unfollow failed"))
                }
            },
            throttleUser: { hexPubkey, maxPosts in
                guard let data = Bech32.hexToData(hexPubkey),
                      let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                ConfigService.shared.throttleProfile(npub, maxPosts: maxPosts)
            },
            dmUser: { hexPubkey in
                NotificationCenter.default.post(
                    name: Notification.Name("OpenDMThread"),
                    object: nil,
                    userInfo: ["pubkey": hexPubkey]
                )
            },
            activeHexPubkey: nostrService.activeHexPubkey
        )
    }
}

private struct FeedActionsKey: EnvironmentKey {
    static let defaultValue = FeedActions()
}

extension EnvironmentValues {
    var feedActions: FeedActions {
        get { self[FeedActionsKey.self] }
        set { self[FeedActionsKey.self] = newValue }
    }
}

// MARK: - FeedNoteRowData

/// Pre-resolved per-row data. Equatable so SwiftUI can skip re-rendering rows
/// whose data has not actually changed (the core 120fps optimization).
struct FeedNoteRowData: Equatable {
    let isLiked: Bool
    /// The kind-7 content of the account's reaction, when it is known.
    let myReaction: String?
    let isReposted: Bool
    let zapAmount: Int?
    let hasNWC: Bool
    let defaultZapAmount: Int
    let hasLightningAddress: Bool
    let zapsOnlyMode: Bool

    let displayPubkey: String
    let displayProfile: FeedProfile?
    let parentNote: FeedNote?
    let parentProfile: FeedProfile?
    let resolvedOriginal: FeedNote?
    let reposterName: String?
    let replyToName: String?
    let isOwnNote: Bool
    let isFollowed: Bool
    let isParentFollowed: Bool
    let stats: NoteStats

    /// Convenience factory to avoid duplicating resolution logic across call sites
    /// (FeedView, NoteDetailView, ProfileView, MenuBarView).
    @MainActor
    static func resolve(
        for note: FeedNote,
        feedService: FeedService,
        nostrService: NostrService
    ) -> FeedNoteRowData {
        let displayPubkey: String = {
            if note.kind == 6 && note.content.isEmpty,
               let refId = note.repostedEventId,
               let original = feedService.findNote(id: refId) {
                return original.pubkey
            }
            return note.pubkey
        }()

        let repostCheckId = note.repostedEventId ?? note.id
        let parentNote = note.parentEventId.flatMap { feedService.findNote(id: $0) }
        let resolvedOriginal: FeedNote? = (note.kind == 6 && note.content.isEmpty)
            ? note.repostedEventId.flatMap { feedService.findNote(id: $0) }
            : nil

        // Likes, zaps and counts on a repost row belong to the note it carries.
        let original = feedService.originalNote(for: note)
        let lud16 = nostrService.profiles[original.pubkey]?.lud16
        let lud06 = nostrService.profiles[original.pubkey]?.lud06
        let hasLightning = (lud16 != nil && !lud16!.isEmpty) || (lud06 != nil && !lud06!.isEmpty)

        return FeedNoteRowData(
            isLiked: feedService.likedEventIds.contains(original.id),
            myReaction: feedService.myReactions[original.id]?.content,
            isReposted: feedService.repostedEventIds.contains(repostCheckId),
            zapAmount: feedService.zappedEventIds[original.id],
            hasNWC: !ConfigService.shared.config.nwcURI.isEmpty,
            defaultZapAmount: ConfigService.shared.config.defaultZapAmount,
            hasLightningAddress: hasLightning,
            zapsOnlyMode: ConfigService.shared.config.zapsOnlyMode,
            displayPubkey: displayPubkey,
            displayProfile: nostrService.profiles[displayPubkey],
            parentNote: parentNote,
            parentProfile: parentNote.flatMap { nostrService.profiles[$0.pubkey] },
            resolvedOriginal: resolvedOriginal,
            reposterName: note.repostedBy.flatMap { nostrService.profiles[$0]?.bestName },
            replyToName: note.replyToPubkey.flatMap { nostrService.profiles[$0]?.bestName },
            isOwnNote: note.pubkey == nostrService.activeHexPubkey,
            isFollowed: feedService.followedPubkeys.contains(displayPubkey),
            isParentFollowed: parentNote.map { feedService.followedPubkeys.contains($0.pubkey) } ?? false,
            stats: feedService.noteStats[original.id] ?? NoteStats()
        )
    }
}

/// The buttons under a post, as the emoji typed into Settings → Post buttons.
/// Only ⚡️ is read: on iOS the zap button on posts and live streams shows
/// only once the user adds it, so App Review sees a labeled
/// opt-in rather than a hidden feature. Profile zaps don't read this, and the
/// Mac always shows zaps.
enum PostButtons {
    static let storageKey = "postButtons"

    static func showsZap(_ value: String) -> Bool {
        #if os(iOS)
        // The emoji keyboard sends ⚡️ (U+26A1 U+FE0F); a bare ⚡ counts too.
        return value.unicodeScalars.contains("\u{26A1}")
        #else
        return true
        #endif
    }
}
