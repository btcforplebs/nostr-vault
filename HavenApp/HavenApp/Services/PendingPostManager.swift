import SwiftUI

@MainActor
class PendingPostManager: ObservableObject {
    static let shared = PendingPostManager()

    enum ActionType: Equatable {
        case reply, quote, newPost, repost

        var label: String {
            switch self {
            case .reply:   return "Replying"
            case .quote:   return "Quoting"
            case .newPost: return "Posting"
            case .repost:  return "Reposting"
            }
        }

        var icon: String {
            switch self {
            case .reply:   return "arrowshape.turn.up.left.fill"
            case .quote:   return "quote.bubble.fill"
            case .newPost: return "paperplane.fill"
            case .repost:  return "arrow.2.squarepath"
            }
        }

        var color: Color {
            switch self {
            case .reply:   return Color(red: 0.22, green: 0.52, blue: 0.95)
            case .quote:   return Color(red: 0.12, green: 0.70, blue: 0.60)
            case .newPost: return Color(red: 0.55, green: 0.18, blue: 0.92)
            case .repost:  return Color(red: 0.55, green: 0.18, blue: 0.92)
            }
        }

        @MainActor
        var themedColor: Color {
            switch self {
            case .reply:   return Color(red: 0.22, green: 0.52, blue: 0.95)
            case .quote:   return Color(red: 0.12, green: 0.70, blue: 0.60)
            case .newPost: return Color.havenPurple
            case .repost:  return Color.havenPurple
            }
        }

        var totalTime: Double {
            self == .repost ? 5.0 : 10.0
        }

        var canEdit: Bool { self != .repost }
    }

    struct EditRequest: Identifiable {
        let id = UUID()
        let content: String
        let replyTo: FeedNote?
        let quoteTo: FeedNote?
    }

    @Published var bannerNoteId: String?
    @Published var actionType: ActionType?
    @Published var timeRemaining: Double = 10.0
    @Published var editRequest: EditRequest?

    private var pendingEvent: NostrEvent?
    private var pendingContent: String = ""
    private var pendingReplyTo: FeedNote?
    private var pendingQuoteTo: FeedNote?
    private var countdown: Task<Void, Never>?

    private init() {}

    func startPost(event: NostrEvent, content: String, replyTo: FeedNote?, quoteTo: FeedNote?, nostrService: NostrService) {
        clearPrevious()
        let type: ActionType = replyTo != nil ? .reply : quoteTo != nil ? .quote : .newPost
        pendingEvent = event
        pendingContent = content
        pendingReplyTo = replyTo
        pendingQuoteTo = quoteTo
        bannerNoteId = event.id
        actionType = type
        timeRemaining = type.totalTime
        beginCountdown { nostrService.postEvent(event) }
    }

    func startRepost(sourceNote: FeedNote, nostrService: NostrService) {
        clearPrevious()
        pendingContent = ""
        pendingReplyTo = nil
        pendingQuoteTo = nil
        bannerNoteId = sourceNote.id
        actionType = .repost
        timeRemaining = ActionType.repost.totalTime

        // NIP-18: always repost the ORIGINAL event, not a repost wrapper.
        // For kind 6 notes, repostedEventId points to the original kind 1 event.
        let originalId = sourceNote.repostedEventId ?? sourceNote.id
        let originalPubkey = sourceNote.pubkey // already swapped to inner author for kind 6

        beginCountdown {
            // NIP-18: content SHOULD be the stringified JSON of the reposted event.
            // Look up from FeedService's raw event cache (includes sig for verification).
            let embedded = FeedService.shared.rawEventCache[originalId] ?? ""

            // NIP-18: e tag MUST include a relay URL as its third entry.
            let relayHint = ConfigService.shared.config.feedRelays.first
                ?? ConfigService.shared.config.blastrRelays.first
                ?? ""

            guard let signed = nostrService.signEvent(
                kind: 6, content: embedded,
                tags: [["e", originalId, relayHint], ["p", originalPubkey]]
            ) else { return }
            nostrService.postEvent(signed)
            FeedService.shared.repostedEventIds.insert(originalId)
        }
    }

    func cancel() {
        countdown?.cancel()
        countdown = nil
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        withAnimation {
            bannerNoteId = nil
            actionType = nil
        }
    }

    func requestEdit() {
        let content = pendingContent
        let replyTo = pendingReplyTo
        let quoteTo = pendingQuoteTo
        countdown?.cancel()
        countdown = nil
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        withAnimation {
            bannerNoteId = nil
            actionType = nil
        }
        editRequest = EditRequest(content: content, replyTo: replyTo, quoteTo: quoteTo)
    }

    private func clearPrevious() {
        countdown?.cancel()
        countdown = nil
        if let event = pendingEvent {
            FeedService.shared.removeNote(id: event.id)
        }
        pendingEvent = nil
        bannerNoteId = nil
        actionType = nil
    }

    private func beginCountdown(onComplete: @escaping @MainActor () -> Void) {
        let ticks = Int(timeRemaining * 10)
        countdown = Task { @MainActor in
            for _ in 0..<ticks {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                self.timeRemaining -= 0.1
            }
            if Task.isCancelled { return }
            withAnimation {
                self.bannerNoteId = nil
                self.actionType = nil
            }
            onComplete()
        }
    }
}
