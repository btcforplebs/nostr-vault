import Foundation

/// Which queued draft saves and deletes may go to the vault now (Mac bug hunt
/// 2026-11-05 #1). They are signed with the active account's key, so each one
/// waits until the account that wrote it is active again; a legacy draft with
/// no author goes with whoever is active, as before.
///
/// Pure Foundation so MediaLogicTests can test it.
enum DraftSyncPlan {
    static func isDue(author: String?, active: String) -> Bool {
        guard let author = author?.lowercased(), !author.isEmpty else { return true }
        return !active.isEmpty && author == active.lowercased()
    }

    /// Splits `items` into the ones to send now and the ones to keep queued.
    static func split<T>(_ items: [T], author: (T) -> String?, active: String) -> (now: [T], later: [T]) {
        var now: [T] = [], later: [T] = []
        for item in items {
            if isDue(author: author(item), active: active) { now.append(item) } else { later.append(item) }
        }
        return (now, later)
    }
}

/// A draft delete waiting for the vault: the draft and the account it was
/// deleted as, so the kind 5's `a` tag names that account's draft.
struct PendingDraftDelete: Hashable, Codable {
    let id: String
    let pubkey: String?
}
