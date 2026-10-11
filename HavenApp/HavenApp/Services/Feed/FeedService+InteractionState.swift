import Foundation
import Combine
import SwiftUI

extension FeedService {
    /// Load engagement state (likes / zaps) for the given account snapshot key.
    /// Delegates to EngagementTracker for the actual disk I/O and migration logic.
    func loadInteractionState(forKey key: String) {
        let result = EngagementTracker.loadInteractionState(forKey: key)
        self.likedEventIds = result.likedEventIds
        self.zappedEventIds = result.zappedEventIds
        self.myReactions = result.myReactions
        self.retractedReactionIds = result.retractedReactionIds
        #if DEBUG
        print("FeedService: Loaded \(result.likedEventIds.count) likes, \(result.zappedEventIds.count) zaps for account \(key.prefix(8))")
        #endif
    }

    func saveInteractionState() {
        // Throttle saves to at most once per 2 seconds. A save inside the
        // window runs at its end instead of being dropped: dropping one lost
        // the newest like (or removal) whenever two came within 2 seconds.
        let now = Date()
        let wait = 2.0 - now.timeIntervalSince(interactionSaveThrottle)
        guard wait <= 0 else {
            guard !interactionSaveScheduled else { return }
            interactionSaveScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
                guard let self else { return }
                self.interactionSaveScheduled = false
                self.saveInteractionState()
            }
            return
        }
        interactionSaveThrottle = now
        writeInteractionState()
    }

    /// Saves the current account's interaction state now, unthrottled.
    func writeInteractionState() {
        EngagementTracker.saveInteractionState(
            EngagementTracker.InteractionState(
                likedEventIds: likedEventIds,
                zappedEventIds: zappedEventIds,
                myReactions: myReactions,
                retractedReactionIds: retractedReactionIds,
                account: loadedSnapshotNpub
            ),
            forKey: loadedSnapshotNpub
        )
    }
}
