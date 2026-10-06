import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
class PendingPostManager: ObservableObject {
    static let shared = PendingPostManager()

    enum ActionType: Equatable {
        case reply, quote, newPost, repost, delete

        var label: String {
            switch self {
            case .reply:   return "Replying"
            case .quote:   return "Quoting"
            case .newPost: return "Posting"
            case .repost:  return "Reposting"
            case .delete:  return "Deleting"
            }
        }

        var icon: String {
            switch self {
            case .reply:   return "arrowshape.turn.up.left.fill"
            case .quote:   return "quote.bubble.fill"
            case .newPost: return "paperplane.fill"
            case .repost:  return "arrow.2.squarepath"
            case .delete:  return "trash.fill"
            }
        }

        var color: Color {
            switch self {
            case .reply:   return Color(red: 0.22, green: 0.52, blue: 0.95)
            case .quote:   return Color(red: 0.12, green: 0.70, blue: 0.60)
            case .newPost: return Color(red: 0.55, green: 0.18, blue: 0.92)
            case .repost:  return Color(red: 0.55, green: 0.18, blue: 0.92)
            case .delete:  return .red
            }
        }

        @MainActor
        var themedColor: Color {
            switch self {
            case .reply:   return Color(red: 0.22, green: 0.52, blue: 0.95)
            case .quote:   return Color(red: 0.12, green: 0.70, blue: 0.60)
            case .newPost: return Color.havenPurple
            case .repost:  return Color.havenPurple
            case .delete:  return .red
            }
        }

        static let countdownDuration: Double = 5.0

        var canEdit: Bool { self != .repost && self != .delete }

        /// Shown once a relay has taken the event.
        var doneLabel: String {
            switch self {
            case .reply:   return "Replied"
            case .quote:   return "Quoted"
            case .newPost: return "Posted"
            case .repost:  return "Reposted"
            case .delete:  return "Deleted"
            }
        }
    }

    /// What happened after the countdown: sending, then either a relay took it
    /// (green) or none confirmed it after the retries (grey, not red: it was
    /// sent, and a slow relay is not a failed post).
    struct Confirmation: Identifiable, Equatable {
        enum State: Equatable { case sending, confirmed, unconfirmed }
        let id = UUID()
        let actionType: ActionType
        var state: State
    }

    struct EditRequest: Identifiable {
        let id = UUID()
        let content: String
        let replyTo: FeedNote?
        let quoteTo: FeedNote?
        /// The saved draft backing the post being edited, so the reopened composer
        /// reuses it instead of leaking an orphan and generating a fresh draft.
        let draftId: String?
    }

    @Published var isShowing = false
    @Published var actionType: ActionType?
    @Published var timeRemaining: Double = 5.0
    @Published var editRequest: EditRequest?
    @Published var confirmation: Confirmation?

    private var bannerNoteId: String?
    private var pendingEvent: NostrEvent?
    private var pendingContent: String = ""
    private var pendingReplyTo: FeedNote?
    private var pendingQuoteTo: FeedNote?
    private var pendingDraftId: String?
    private var countdown: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Cancel any pending post when the active account switches,
        // preventing a post composed under one account from being
        // published under a different account's signing key.
        ConfigService.shared.$config
            .map { $0.activeAccountNpub }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cancel()
            }
            .store(in: &cancellables)
    }

    /// `draftId`, when provided, is the saved draft backing this post. It is deleted only
    /// once the post actually broadcasts (after the countdown) — not at hand-off — so a crash
    /// or cancel during the pending window leaves the user's text recoverable.
    func startPost(event: NostrEvent, content: String, replyTo: FeedNote?, quoteTo: FeedNote?, nostrService: NostrService, draftId: String? = nil) {
        clearPrevious()
        let type: ActionType = replyTo != nil ? .reply : quoteTo != nil ? .quote : .newPost
        pendingEvent = event
        pendingContent = content
        pendingReplyTo = replyTo
        pendingQuoteTo = quoteTo
        pendingDraftId = draftId
        bannerNoteId = event.id
        actionType = type
        timeRemaining = ActionType.countdownDuration
        withAnimation(Motion.bannerIn) { isShowing = true }
        beginCountdown {
            let confirmationId = self.beginConfirmation(type)
            nostrService.postEvent(event) { outcome in
                self.finishConfirmation(confirmationId, outcome: outcome)
            }
            // The note is now broadcasting — safe to drop its draft.
            if let draftId {
                await DraftService.shared.deleteDraft(id: draftId)
            }
        }
    }

    func startRepost(sourceNote: FeedNote, nostrService: NostrService) {
        clearPrevious()
        pendingContent = ""
        pendingReplyTo = nil
        pendingQuoteTo = nil
        bannerNoteId = sourceNote.id
        actionType = .repost
        timeRemaining = ActionType.countdownDuration
        withAnimation(Motion.bannerIn) { isShowing = true }

        // NIP-18: always repost the ORIGINAL event, not a repost wrapper.
        // For kind 6 notes, repostedEventId points to the original kind 1 event
        // (the only kind this app has ever wrapped in kind 6).
        let originalId = sourceNote.repostedEventId ?? sourceNote.id
        // A bare repost still carries the reposter's pubkey; only an embedded
        // one was swapped to the inner author.
        let originalPubkey = FeedService.shared.originalNote(for: sourceNote).pubkey
        let originalKind = sourceNote.repostedEventId != nil ? 1 : sourceNote.kind

        beginCountdown {
            let confirmationId = self.beginConfirmation(.repost)
            // NIP-18: content SHOULD be the stringified JSON of the reposted event.
            // Look up from FeedService's raw event cache (includes sig for verification).
            let embedded = FeedService.shared.rawEventCache[originalId] ?? ""

            // NIP-18: e tag MUST include a relay URL as its third entry.
            let relayHint = ConfigService.shared.config.activeFeedRelays.first
                ?? ConfigService.shared.config.activeBlastrRelays.first
                ?? ConfigService.shared.config.nostrURL

            // NIP-18: kind 6 is reserved for reposting kind-1 notes. Anything else
            // (e.g. a kind-30023 long-form article) needs kind 16 with a "k" tag
            // naming the original kind, or most clients will reject/ignore it.
            let repostKind = originalKind == 1 ? 6 : 16
            var tags: [[String]] = [["e", originalId, relayHint], ["p", originalPubkey]]
            if repostKind == 16 {
                tags.append(["k", String(originalKind)])
            }

            let powSnap = PowPreferences.snapshot()
            let powDiff = powSnap.noteEnabled ? powSnap.noteDifficulty : 0
            if let signed = await nostrService.mineAndSignEventAsync(
                kind: repostKind, content: embedded,
                tags: tags,
                difficulty: powDiff
            ) {
                nostrService.postEvent(signed) { outcome in
                    self.finishConfirmation(confirmationId, outcome: outcome)
                }
            } else {
                self.finishConfirmation(confirmationId, outcome: nil)
            }
            FeedService.shared.repostedEventIds.insert(originalId)
        }
    }

    func startDelete(noteId: String, nostrService: NostrService, feedService: FeedService) {
        clearPrevious()
        pendingContent = ""
        pendingReplyTo = nil
        pendingQuoteTo = nil
        bannerNoteId = noteId
        actionType = .delete
        timeRemaining = ActionType.countdownDuration
        withAnimation(Motion.bannerIn) { isShowing = true }

        beginCountdown {
            nostrService.deleteNote(id: noteId)
            feedService.removeNote(id: noteId)
        }
    }

    func cancel() {
        countdown?.cancel()
        countdown = nil
        endBackgroundTaskIfNeeded()
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        pendingDraftId = nil
        withAnimation(Motion.bannerOut) {
            isShowing = false
            actionType = nil
        }
        bannerNoteId = nil
    }

    /// Hides the countdown banner without touching the pending action — the
    /// swipe-up gesture on the pill. The countdown Task, its background-task
    /// assertion, and the eventual broadcast all continue untouched; the user is
    /// saying "I'm not going to undo this, stop covering my screen", which is
    /// the opposite of `cancel()`.
    func dismissBanner() {
        guard isShowing else { return }
        withAnimation(Motion.bannerOut) {
            isShowing = false
        }
    }

    func requestEdit() {
        let content = pendingContent
        let replyTo = pendingReplyTo
        let quoteTo = pendingQuoteTo
        countdown?.cancel()
        countdown = nil
        endBackgroundTaskIfNeeded()
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        withAnimation(Motion.bannerOut) {
            isShowing = false
            actionType = nil
        }
        bannerNoteId = nil
        let draftId = pendingDraftId
        pendingDraftId = nil
        editRequest = EditRequest(content: content, replyTo: replyTo, quoteTo: quoteTo, draftId: draftId)
    }

    private func beginConfirmation(_ type: ActionType) -> UUID {
        let confirmation = Confirmation(actionType: type, state: .sending)
        withAnimation(Motion.bannerIn) { self.confirmation = confirmation }
        return confirmation.id
    }

    /// `nil` outcome: nothing was sent (signing failed), so just clear it.
    private func finishConfirmation(_ id: UUID, outcome: BroadcastTally.Outcome?) {
        guard confirmation?.id == id else { return }
        guard let outcome else {
            withAnimation(Motion.bannerOut) { confirmation = nil }
            return
        }
        withAnimation(Motion.fade) {
            confirmation?.state = outcome == .accepted ? .confirmed : .unconfirmed
        }
        let delay: TimeInterval = outcome == .accepted ? 2.5 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.confirmation?.id == id else { return }
            withAnimation(Motion.bannerOut) { self?.confirmation = nil }
        }
    }

    private func clearPrevious() {
        countdown?.cancel()
        countdown = nil
        endBackgroundTaskIfNeeded()
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        pendingDraftId = nil
        isShowing = false
        bannerNoteId = nil
        actionType = nil
    }

    private func beginCountdown(onComplete: @escaping @MainActor () async -> Void) {
        // Covers the countdown + mine/sign + broadcast that follows it, so the
        // OS doesn't suspend/kill the app mid-post if the user backgrounds it
        // (e.g. locks the phone) right after tapping post — PoW mining can
        // make this window last several seconds.
        beginBackgroundTask()
        let endTime = Date().addingTimeInterval(ActionType.countdownDuration)
        countdown = Task { @MainActor in
            while Date() < endTime {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled {
                    self.endBackgroundTaskIfNeeded()
                    return
                }
                self.timeRemaining = max(0, endTime.timeIntervalSinceNow)
            }
            if Task.isCancelled {
                self.endBackgroundTaskIfNeeded()
                return
            }
            withAnimation(Motion.bannerOut) {
                self.isShowing = false
                self.actionType = nil
            }
            self.bannerNoteId = nil
            await onComplete()
            self.endBackgroundTaskIfNeeded()
        }
    }

    #if os(iOS)
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private func beginBackgroundTask() {
        endBackgroundTaskIfNeeded()
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "PendingPostBroadcast", expirationHandler: nil)
    }

    private func endBackgroundTaskIfNeeded() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }
    #else
    private func beginBackgroundTask() {}
    private func endBackgroundTaskIfNeeded() {}
    #endif
}
