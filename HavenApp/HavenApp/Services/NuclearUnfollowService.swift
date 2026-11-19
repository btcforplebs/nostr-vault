import Foundation

/// Nuclear unfollow for the active account (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md):
/// who you follow that follows X, and the one follow-list change that cuts
/// them, kept undoable through the vault's list history. Rules in
/// NuclearUnfollowPlan. Android/web twins: their own lanes.
@MainActor
enum NuclearUnfollowService {
    /// Everyone you follow whose newest follow list has X, sorted by key.
    /// `complete` is false when relays stopped answering before the end, so
    /// the screen can say the list may be short.
    static func bridges(to target: String) async -> (people: [String], complete: Bool) {
        let me = ConfigService.shared.activeAccountHexPubkey
        let follows = FeedService.shared.followedPubkeys
        let path = await TrustPathService.shared.path(for: target)
        if path.complete { return (path.all, true) }
        var found = Set(path.all)
        var lists: [[String: Any]] = []
        var seen = found
        // Relays hand back a few lists per ask; ask until nothing new comes.
        for _ in 0..<maxRounds {
            guard let batch = await TrustPathService.shared.moreBridgeLists(author: target, follows: follows, seen: seen) else {
                return (merged(found, lists, target: target, me: me, follows: follows), false)
            }
            if batch.isEmpty { return (merged(found, lists, target: target, me: me, follows: follows), true) }
            lists += batch
            for list in batch { if let signer = list["pubkey"] as? String { seen.insert(signer) } }
            found.formUnion(TrustPath.allBridges(author: target, me: me, follows: Set(follows), contactLists: batch))
        }
        return (merged(found, lists, target: target, me: me, follows: follows), false)
    }

    /// About 6 lists per ask: 200 asks is over 1,000 people.
    private static let maxRounds = 200

    private static func merged(_ found: Set<String>, _ lists: [[String: Any]], target: String,
                               me: String, follows: [String]) -> [String] {
        found.union(TrustPath.allBridges(author: target, me: me, follows: Set(follows), contactLists: lists)).sorted()
    }

    enum Outcome {
        /// Published; `backup` is the list as it was, for Undo.
        case done(removed: Int, backup: NostrEvent?)
        case unchanged
        case refused(String)
    }

    /// Cuts `removing` from the newest follow list. The vault keeps the
    /// newest list first (`onBackupSaved`), and nothing is signed when it
    /// can't (ListVersionSave). Every other tag and the content stay.
    static func unfollow(_ removing: Set<String>, onBackupSaved: @escaping @MainActor () -> Void) async -> Outcome {
        let me = ConfigService.shared.activeAccountHexPubkey
        var backup: NostrEvent?
        let outcome = await NostrService.shared.saveListVersion(kind: 3, author: me, verb: "unfollow",
                                                                onUndoCopyKept: onBackupSaved) { newest in
            backup = newest
            switch NuclearUnfollowPlan.newTags(base: newest?.tags, removing: removing) {
            case .ready(let tags): return .ready(tags: tags, content: newest?.content ?? "")
            case .unchanged: return .unchanged
            case .refuse(let why): return .refuse(why)
            }
        }
        return finish(outcome, removed: removing.count, backup: backup)
    }

    /// Undo: the follow list as it was before, as a new version (the cut one
    /// stays in the list history too).
    static func undo(to backup: NostrEvent) async -> Outcome {
        let me = ConfigService.shared.activeAccountHexPubkey
        guard backup.pubkey == me, backup.kind == 3 else {
            return .refused("That backup belongs to another account. Switch to it first.")
        }
        let outcome = await NostrService.shared.saveListVersion(kind: 3, author: me, verb: "undo") { _ in
            .ready(tags: backup.tags, content: backup.content)
        }
        return finish(outcome, removed: 0, backup: nil)
    }

    private static func finish(_ outcome: ListVersionSave.Outcome<NostrEvent>, removed: Int,
                               backup: NostrEvent?) -> Outcome {
        switch outcome {
        case .saved:
            // The feed, follow buttons and WoT gate read the new list.
            Task { await FeedService.shared.refreshContactList() }
            return .done(removed: removed, backup: backup)
        case .unchanged: return .unchanged
        case .refused(let why, _): return .refused(why)
        }
    }
}
