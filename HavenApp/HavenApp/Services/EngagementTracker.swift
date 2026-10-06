import Foundation

/// Pure engagement bookkeeping — likes, zaps, reposts, and per-note stats.
/// No Combine, no @Published. FeedService delegates state mutations here
/// and assigns results to its published properties.
enum EngagementTracker {

    /// The reaction the signed-in account left on a note: its kind-7
    /// `content`, and the event that carried it, so removing it can publish a
    /// NIP-09 deletion. `eventId` is nil while the reaction is being signed.
    struct MyReaction: Codable, Equatable {
        let content: String
        var eventId: String?
    }

    /// One kind-7 event seen on a relay.
    struct ReactionEvent {
        let targetId: String
        let pubkey: String
        let eventId: String
        let content: String
    }

    // MARK: - Interaction State (Persistence Model)

    /// Codable snapshot of the user's engagement state (which notes they've
    /// liked/zapped), persisted to disk per account.
    struct InteractionState: Codable {
        let likedEventIds: Set<String>
        let zappedEventIds: [String: Int]
        /// Which emoji each liked note got. Missing in files written before it
        /// existed; those notes show the plain heart.
        let myReactions: [String: MyReaction]
        /// Reactions this account removed. Relays may keep serving them after
        /// the deletion, and seeing one again must not bring the like back.
        let retractedReactionIds: Set<String>
        /// The account key this was saved for. Missing in files written before
        /// it existed, which may hold another account's likes.
        let account: String?

        init(likedEventIds: Set<String>, zappedEventIds: [String: Int],
             myReactions: [String: MyReaction] = [:], retractedReactionIds: Set<String> = [],
             account: String? = nil) {
            self.likedEventIds = likedEventIds
            self.zappedEventIds = zappedEventIds
            self.myReactions = myReactions
            self.retractedReactionIds = retractedReactionIds
            self.account = account
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            account = try container.decodeIfPresent(String.self, forKey: .account)
            likedEventIds = try container.decode(Set<String>.self, forKey: .likedEventIds)
            myReactions = try container.decodeIfPresent([String: MyReaction].self, forKey: .myReactions) ?? [:]
            retractedReactionIds = try container.decodeIfPresent(Set<String>.self, forKey: .retractedReactionIds) ?? []
            // Migrate from old Set<String> format if needed
            if let dict = try? container.decode([String: Int].self, forKey: .zappedEventIds) {
                zappedEventIds = dict
            } else if let set = try? container.decode(Set<String>.self, forKey: .zappedEventIds) {
                zappedEventIds = Dictionary(uniqueKeysWithValues: set.map { ($0, 0) })
            } else {
                zappedEventIds = [:]
            }
        }
    }

    // MARK: - File Paths

    /// Returns the per-account interaction state file URL.
    static func interactionStateURL(forKey key: String) -> URL {
        let havenDir = havenSupportDir()
        let safeKey = key.isEmpty ? "owner" : key.replacingOccurrences(of: "/", with: "_")
        return havenDir.appendingPathComponent("interaction_state_\(safeKey).json")
    }


    private static func havenSupportDir() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Haven")
        }
        let havenDir = appSupport.appendingPathComponent("Haven", isDirectory: true)
        try? FileManager.default.createDirectory(at: havenDir, withIntermediateDirectories: true)
        return havenDir
    }

    // MARK: - Load / Save

    /// Loads interaction state from disk for the given account key.
    ///
    /// Only a file stamped with this account is trusted. Unstamped files
    /// (written before the stamp, and the old shared file) can hold another
    /// account's likes: a late account switch used to save one account's set
    /// under the next. They start empty instead, and the account's own
    /// reactions rebuild its likes as the feed loads.
    static func loadInteractionState(forKey key: String) -> InteractionState {
        let url = interactionStateURL(forKey: key)
        if let data = try? Data(contentsOf: url),
           let state = try? JSONDecoder().decode(InteractionState.self, from: data),
           accepts(state, forKey: key) {
            return state
        }
        return InteractionState(likedEventIds: [], zappedEventIds: [:], account: key)
    }

    /// Whether a saved state belongs to the account `key`.
    static func accepts(_ state: InteractionState, forKey key: String) -> Bool {
        state.account == key
    }

    /// Persists interaction state to disk. Runs the encode + write on a
    /// background queue to avoid blocking the main thread.
    static func saveInteractionState(_ state: InteractionState, forKey key: String) {
        let url = interactionStateURL(forKey: key)
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Self-Like Detection

    /// The owner's own reactions in a batch, keyed by the note they react
    /// to. Reactions the owner has since removed are skipped.
    static func detectSelfReactions(
        reactions: [ReactionEvent],
        ownerHex: String,
        retracted: Set<String>
    ) -> [String: MyReaction] {
        guard !ownerHex.isEmpty else { return [:] }
        var mine: [String: MyReaction] = [:]
        for rx in reactions where rx.pubkey == ownerHex && !retracted.contains(rx.eventId) {
            mine[rx.targetId] = MyReaction(content: rx.content, eventId: rx.eventId)
        }
        return mine
    }

    // MARK: - Engagement Count Merging

    /// Merges a batch of reaction events and repost targets into the running
    /// per-note stats dictionary. Returns the updated dictionary.
    static func mergeEngagementCounts(
        reactions: [ReactionEvent],
        repostTargets: [String],
        currentStats: [String: NoteStats],
        retracted: Set<String> = []
    ) -> [String: NoteStats] {
        var updated = currentStats
        for rx in reactions where !retracted.contains(rx.eventId) {
            let targetId = rx.targetId
            var s = updated[targetId] ?? NoteStats()
            s.reactions += 1
            updated[targetId] = s
        }
        for targetId in repostTargets {
            var s = updated[targetId] ?? NoteStats()
            s.reposts += 1
            updated[targetId] = s
        }
        return updated
    }
}
