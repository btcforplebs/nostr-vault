import Foundation

/// Nuclear unfollow for the active account (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md):
/// who you follow that follows X, and the one follow-list change that cuts
/// them, kept undoable through the vault's list history. Rules in
/// NuclearUnfollowPlan. Android/web twins: their own lanes.
@MainActor
enum NuclearUnfollowService {
    /// Who you follow that follows X. `confirmed`: their newest follow list,
    /// fetched from relays now, has X. `fromSavedWeb`: only the relay's saved
    /// web (the last WoT rebuild) names them, so they may have stopped since.
    /// `complete` is false when relays stopped answering before the end.
    struct Found {
        var confirmed: [String]
        var fromSavedWeb: [String]
        var complete: Bool
        var everyone: [String] { (confirmed + fromSavedWeb).sorted() }
    }

    static func bridges(to target: String) async -> Found {
        let me = ConfigService.shared.activeAccountHexPubkey
        let follows = FeedService.shared.followedPubkeys
        // The saved web is only a seed (Tron, #2282): relays are always asked.
        let seed = Set(await TrustPathService.shared.path(for: target).all)
        var confirmed = Set<String>()
        var seen = Set<String>()
        var complete = false
        // Relays hand back a few lists per ask; ask until nothing new comes.
        // Each answer has only signers not seen yet, so this can't loop.
        for _ in 0..<maxRounds {
            guard let batch = await TrustPathService.shared.moreBridgeLists(author: target, follows: follows, seen: seen) else {
                break
            }
            if batch.isEmpty { complete = true; break }
            for list in batch { if let signer = list["pubkey"] as? String { seen.insert(signer) } }
            confirmed.formUnion(TrustPath.allBridges(author: target, me: me, follows: Set(follows), contactLists: batch))
        }
        return Found(confirmed: confirmed.sorted(), fromSavedWeb: seed.subtracting(confirmed).sorted(), complete: complete)
    }

    /// About 6 lists per ask: 200 asks is over 1,000 people.
    private static let maxRounds = 200

    enum Outcome {
        /// Published; `backup` is the list as it was, for Undo, and
        /// `cut` the follows actually removed.
        case done(removed: Int, backup: NostrEvent?, cut: Set<String>)
        case unchanged
        case refused(String)
    }

    /// Cuts `removing` from the newest follow list. The vault keeps the
    /// newest list first (`onBackupSaved`), and nothing is signed when it
    /// can't (ListVersionSave). Every other tag and the content stay.
    static func unfollow(_ removing: Set<String>, onBackupSaved: @escaping @MainActor () -> Void) async -> Outcome {
        let me = ConfigService.shared.activeAccountHexPubkey
        var backup: NostrEvent?
        var removed = 0
        let outcome = await NostrService.shared.saveListVersion(kind: 3, author: me, verb: "unfollow",
                                                                onUndoCopyKept: onBackupSaved) { newest in
            backup = newest
            switch NuclearUnfollowPlan.newTags(base: newest?.tags, removing: removing) {
            case .ready(let tags):
                removed = NuclearUnfollowPlan.removedCount(base: newest?.tags ?? [], tags: tags)
                return .ready(tags: tags, content: newest?.content ?? "")
            case .unchanged: return .unchanged
            case .refuse(let why): return .refuse(why)
            }
        }
        return finish(outcome, removed: removed, backup: backup, cut: removing)
    }

    /// Undo: the people the cut removed are followed again, on top of the
    /// newest list, so anything changed since stays (Tron, #2282). A new
    /// version; the cut one stays in the list history too.
    static func undo(to backup: NostrEvent, cut: Set<String>) async -> Outcome {
        let me = ConfigService.shared.activeAccountHexPubkey
        guard backup.pubkey == me, backup.kind == 3 else {
            return .refused("That backup belongs to another account. Switch to it first.")
        }
        let outcome = await NostrService.shared.saveListVersion(kind: 3, author: me, verb: "undo") { newest in
            guard let tags = NuclearUnfollowPlan.undoTags(newest: newest?.tags, backup: backup.tags, removed: cut) else {
                return .refuse("Your follow list couldn't be found, so nothing was changed.")
            }
            return tags == newest?.tags ? .unchanged : .ready(tags: tags, content: newest?.content ?? backup.content)
        }
        return finish(outcome, removed: 0, backup: nil, cut: [])
    }

    private static func finish(_ outcome: ListVersionSave.Outcome<NostrEvent>, removed: Int,
                               backup: NostrEvent?, cut: Set<String>) -> Outcome {
        switch outcome {
        case .saved:
            // The feed, follow buttons and WoT gate read the new list.
            Task { await FeedService.shared.refreshContactList() }
            return .done(removed: removed, backup: backup, cut: cut)
        case .unchanged: return .unchanged
        case .refused(let why, _): return .refused(why)
        }
    }
}
