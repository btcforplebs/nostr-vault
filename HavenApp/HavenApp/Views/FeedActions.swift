import SwiftUI

struct ComposeContext: Identifiable {
    let id = UUID()
    let replyTo: FeedNote?
    let quoteTo: FeedNote?
    var initialContent: String = ""
    var draftId: String? = nil
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
    var zapNote: (FeedNote, String, Int?) async -> Void = { _, _, _ in }
    var getLightningAddress: (String) -> String? = { _ in nil }

    // Delete
    var deleteNote: (String) -> Void = { _ in }

    // Missing content fetching
    var fetchMissingNote: (String) -> Void = { _ in }
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

    /// Shared factory so FeedView, NoteDetailView, ProfileView, and MenuBarView
    /// don't each duplicate ~70 lines of closure construction.
    @MainActor
    static func make(feedService: FeedService, nostrService: NostrService) -> FeedActions {
        FeedActions(
            likeNote: { note in
                let noteId = note.id
                if feedService.likedEventIds.contains(noteId) { return }
                feedService.likedEventIds.insert(noteId)
                var stats = feedService.noteStats[noteId] ?? NoteStats()
                stats.reactions += 1
                feedService.noteStats[noteId] = stats
                feedService.saveInteractionState()
                let relayHint = ConfigService.shared.config.nostrURL
                Task {
                    let powSnap = PowPreferences.snapshot()
                    let powDiff = powSnap.reactionEnabled ? powSnap.reactionDifficulty : 0
                    guard let signed = await nostrService.mineAndSignEventAsync(kind: 7, content: ConfigService.shared.config.defaultReactionEmoji,
                        tags: [["e", noteId, relayHint], ["p", note.pubkey], ["k", String(note.kind)]], difficulty: powDiff) else {
                        // Rollback optimistic update on signing failure
                        await MainActor.run {
                            feedService.likedEventIds.remove(noteId)
                            var s = feedService.noteStats[noteId] ?? NoteStats()
                            s.reactions = max(0, s.reactions - 1)
                            feedService.noteStats[noteId] = s
                            feedService.saveInteractionState()
                        }
                        return
                    }
                    nostrService.postEvent(signed)
                }
            },
            unlikeNote: { note in
                UnlikeNotificationManager.shared.startCountdown {
                    feedService.likedEventIds.remove(note.id)
                    var stats = feedService.noteStats[note.id] ?? NoteStats()
                    stats.reactions = max(0, stats.reactions - 1)
                    feedService.noteStats[note.id] = stats
                    feedService.saveInteractionState()
                }
            },
            reactToNote: { note, emoji in
                let wasAlreadyLiked = feedService.likedEventIds.contains(note.id)
                if !wasAlreadyLiked {
                    feedService.likedEventIds.insert(note.id)
                    var stats = feedService.noteStats[note.id] ?? NoteStats()
                    stats.reactions += 1
                    feedService.noteStats[note.id] = stats
                    feedService.saveInteractionState()
                }
                let relayHint = ConfigService.shared.config.nostrURL
                Task {
                    let powSnap = PowPreferences.snapshot()
                    let powDiff = powSnap.reactionEnabled ? powSnap.reactionDifficulty : 0
                    guard let signed = await nostrService.mineAndSignEventAsync(kind: 7, content: emoji,
                        tags: [["e", note.id, relayHint], ["p", note.pubkey], ["k", String(note.kind)]], difficulty: powDiff) else {
                        // Rollback optimistic update on signing failure
                        if !wasAlreadyLiked {
                            await MainActor.run {
                                feedService.likedEventIds.remove(note.id)
                                var s = feedService.noteStats[note.id] ?? NoteStats()
                                s.reactions = max(0, s.reactions - 1)
                                feedService.noteStats[note.id] = s
                                feedService.saveInteractionState()
                            }
                        }
                        return
                    }
                    nostrService.postEvent(signed)
                }
            },
            repostNote: { note in
                PendingPostManager.shared.startRepost(sourceNote: note, nostrService: nostrService)
            },
            zapNote: { note, lud16, amount in
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
                } catch {
                    #if DEBUG
                    print("FeedActions: Zap failed: \(error)")
                    #endif
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
            fetchMissingProfiles: { pks in nostrService.fetchMissingProfiles(for: pks) },
            findNote: { id in feedService.findNote(id: id) },
            blockUser: { hexPubkey in
                guard let data = Bech32.hexToData(hexPubkey),
                      let npub = Bech32.encode(hrp: "npub", data: data) else { return }
                ConfigService.shared.blockProfile(npub)
            },
            followUser: { hexPubkey in
                let _ = feedService.followUser(hexPubkey)
            },
            unfollowUser: { hexPubkey in
                let _ = feedService.unfollowUser(hexPubkey)
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

        let lud16 = nostrService.profiles[note.pubkey]?.lud16
        let lud06 = nostrService.profiles[note.pubkey]?.lud06
        let hasLightning = (lud16 != nil && !lud16!.isEmpty) || (lud06 != nil && !lud06!.isEmpty)

        return FeedNoteRowData(
            isLiked: feedService.likedEventIds.contains(note.id),
            isReposted: feedService.repostedEventIds.contains(repostCheckId),
            zapAmount: feedService.zappedEventIds[note.id],
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
            stats: feedService.noteStats[note.id] ?? NoteStats()
        )
    }
}
