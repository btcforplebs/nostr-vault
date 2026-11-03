import Foundation

// MARK: - Inbox (app side)
//
// Claims what the share extension queued (NVShareQueue) into the app's own
// folder, finishes the actions that need no card, and holds the rest for the
// review sheet. A claimed intent stays on disk until it is posted or
// discarded, so a review survives the app being killed.

@MainActor
final class SharePortalInbox: ObservableObject {
    static let shared = SharePortalInbox()

    /// Intents waiting for a review, oldest first.
    @Published private(set) var waiting: [NVShareIntent] = []
    /// The one the review sheet shows.
    @Published var presented: NVShareIntent?

    private let claimed: NVShareQueue

    init(claimed: NVShareQueue = SharePortalInbox.defaultClaimed) {
        self.claimed = claimed
    }

    nonisolated static var defaultClaimed: NVShareQueue {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return NVShareQueue(root: base.appendingPathComponent("SharePortal/Claimed", isDirectory: true))
    }

    /// Takes everything the extension left, runs the no-card actions, then
    /// shows the oldest waiting review. Safe to call twice: claiming is a move.
    func claim(from queue: NVShareQueue? = NVShareQueue.shared) {
        guard ConfigService.shared.config.hasCompletedSetup else { return }
        if let queue {
            for intent in queue.claimAll(into: claimed) {
                let handler = SharePortalRouter.handler(for: intent.action)
                guard !handler.needsReview else { continue }
                handler.handleOnClaim(intent)
                claimed.remove(id: intent.id)
            }
        }
        reload(present: true)
    }

    /// Re-reads the claimed folder. With `present`, opens the sheet on the
    /// oldest one if none is showing.
    func reload(present: Bool) {
        waiting = claimed.all()
        if let shown = presented, !waiting.contains(where: { $0.id == shown.id }) { presented = nil }
        if present, presented == nil { presented = waiting.first }
    }

    /// Posted or discarded: the intent and its files are deleted, and the
    /// next one (if any) is shown.
    func finish(_ intent: NVShareIntent) {
        claimed.remove(id: intent.id)
        presented = nil
        reload(present: false)
        guard !waiting.isEmpty else { return }
        // A beat so the closing sheet is gone before the next one opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reload(present: true)
        }
    }

    func fileURL(for file: NVShareIntent.File, of intent: NVShareIntent) -> URL? {
        claimed.fileURL(for: file, of: intent)
    }
}
