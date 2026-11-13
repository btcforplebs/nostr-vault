import Foundation

/// The Vault tab on return and on an account switch (Logen 2026-11-13: "the
/// Vault tab button is red and the tab has a hard time loading; I see new
/// followers first, then everything else gets injected after").
///
/// Pure rules, so MediaLogicTests can hold them; the app wires them in
/// VaultView (the list swap), NostrService+VaultSnapshot (the saved screen)
/// and RelayProcessManager+NewsDot (one dot per account).
enum VaultListSwap {
    /// The longest a refresh keeps the old list up before the new one shows
    /// anyway, so a relay that never says EOSE can't freeze the screen.
    static let cap: TimeInterval = 3

    /// Whether a freshly built Vault list goes on screen now. While a refresh
    /// is reading, the list on screen stays and the new one waits until the
    /// read is done (or `cap` passed), so rows don't pop in one batch at a
    /// time and followers (read from disk, first) never show alone.
    /// `force`: the build is the saved screen for an account just switched
    /// to, which shows at once.
    static func publishes(force: Bool, refreshing: Bool, heldFor: TimeInterval?) -> Bool {
        if force || !refreshing { return true }
        guard let heldFor else { return false }
        return heldFor >= cap
    }
}

/// What the saved Vault screen keeps: the newest events, enough for the
/// first page of every Vault list.
enum VaultSnapshotRules {
    static let keep = 400

    /// The newest `keep` items, newest first.
    static func newest<T>(_ items: [T], keep: Int = keep, createdAt: (T) -> Int64) -> [T] {
        Array(items.sorted { createdAt($0) > createdAt($1) }.prefix(keep))
    }

    /// The file name for an account's saved screen: its hex pubkey, nothing
    /// else, so a malformed key can't reach outside the folder.
    static func fileName(account hex: String) -> String? {
        let hex = hex.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "vault-\(hex).json"
    }
}

/// The Vault tab's dot, one per account: each account keeps its own lists
/// with news and its own count of unread messages already seen, and a list
/// lights only for something dated after that account's last visit.
struct VaultNewsAccounts<Mode: Hashable> {
    private(set) var modes: [String: Set<Mode>] = [:]
    private(set) var dmSeen: [String: Int] = [:]

    /// Stash what `from` shows now and hand back what `to` showed when you
    /// last left it (nothing new, nothing seen, for one never opened here).
    mutating func switchAccount(from: String, to: String, modes current: Set<Mode>, dmSeen seen: Int) -> (modes: Set<Mode>, dmSeen: Int) {
        let from = from.lowercased(), to = to.lowercased()
        if !from.isEmpty {
            modes[from] = current
            dmSeen[from] = seen
        }
        guard from != to else { return (current, seen) }
        return (modes[to] ?? [], dmSeen[to] ?? 0)
    }

    /// Whether events from others dated `createdAt` are news to an account
    /// whose Vault was last seen at `lastVisit` (unix seconds; nil = never).
    /// A catch-up storing an old like you already saw elsewhere is not.
    static func isNews(createdAt: [Int64], lastVisit: Int64?) -> Bool {
        guard let lastVisit else { return !createdAt.isEmpty }
        return createdAt.contains { $0 > lastVisit }
    }
}
