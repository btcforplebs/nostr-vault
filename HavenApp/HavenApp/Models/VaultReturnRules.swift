import Foundation

/// The Vault tab on return and on an account switch (Logen 2026-11-13: "the
/// Vault tab button is red and the tab has a hard time loading; I see new
/// followers first, then everything else gets injected after").
///
/// Pure rules, so MediaLogicTests can hold them; the app wires them in
/// VaultView (the list swap), NostrService+VaultDirectRead (the store read)
/// and RelayProcessManager+NewsDot (one dot per account).
enum VaultListSwap {
    /// The longest a refresh keeps the old list up before the new one shows
    /// anyway, so a relay that never says EOSE can't freeze the screen.
    static let cap: TimeInterval = 3

    /// Whether a freshly built Vault list goes on screen now. While a refresh
    /// is reading, the list on screen stays and the new one waits until the
    /// read is done (or `cap` passed), so rows don't pop in one batch at a
    /// time and followers (read from disk, first) never show alone.
    static func publishes(refreshing: Bool, heldFor: TimeInterval?) -> Bool {
        if !refreshing { return true }
        guard let heldFor else { return false }
        return heldFor >= cap
    }
}

/// The Vault reads its rows straight from the on-device store (Logen
/// 2026-11-14, NostrService+VaultDirectRead): tens of ms, whatever the relay
/// port is doing. The socket stays for live updates and the Mac relay.
enum VaultDirectRead {
    /// Whether the Vault list counts as reading (VaultListSwap holds it).
    /// Once the store read answered for this account, only that read holds
    /// the list; the socket after it tops up live and never holds it. Before
    /// that (engine not up yet, or a store not ready): the socket read and
    /// the boot do, as before, and nothing read yet counts as reading, so
    /// followers never show alone.
    static func reading(storeAnswered: Bool, storeReading: Bool, socketReading: Bool,
                        booting: Bool, nothingYet: Bool) -> Bool {
        if storeAnswered { return storeReading }
        return storeReading || socketReading || booting || nothingYet
    }

    /// `since` for a store read: the whole window the first time for an
    /// account, only what's new after that.
    static func storeSince(answeredBefore: Bool, newest: Int64?, now: Int64) -> Int64? {
        answeredBefore ? VaultActivity.refreshSince(newest: newest, now: now) : nil
    }

    /// A first store read's filters in two passes (startup, Logen
    /// 2026-11-14: rows < 0.5 s): the row kinds first, then the follower
    /// lists (kind 3). On a phone those lists were 213 of 400 events and most
    /// of a 15 MB answer, and the rows don't need them to draw. Each filter
    /// that asks for kind 3 is cut in two, same limit, so neither pass starves
    /// the other. Later reads (only what's new) stay one pass.
    static func storePasses(_ filters: [[String: Any]], split: Bool) -> (first: [[String: Any]], after: [[String: Any]]) {
        guard split else { return (filters, []) }
        var first: [[String: Any]] = []
        var after: [[String: Any]] = []
        for filter in filters {
            guard let kinds = filter["kinds"] as? [Int], kinds.contains(3) else {
                first.append(filter)
                continue
            }
            let rest = kinds.filter { $0 != 3 }
            if !rest.isEmpty {
                var f = filter
                f["kinds"] = rest
                first.append(f)
            }
            var lists = filter
            lists["kinds"] = [3]
            after.append(lists)
        }
        return (first, after)
    }

    /// Whether a store read that came back not ready tries again (every
    /// notReadyRetry): only while the engine is still starting, up to
    /// notReadyGiveUp. The read no longer waits for the "ready" log line,
    /// which reached the app ~180 ms after the store could answer.
    static func retriesNotReady(booting: Bool, waited: TimeInterval) -> Bool {
        booting && waited < notReadyGiveUp
    }
    static let notReadyRetry: UInt64 = 20_000_000 // 20 ms
    static let notReadyGiveUp: TimeInterval = 5

    /// `since` for the socket read of a refresh. After a store read the
    /// socket only tops up; a full refresh still reads everything when the
    /// store didn't answer, or from a Mac relay, which the store can't see.
    static func socketSince(full: Bool, storeAnswered: Bool, remoteRelay: Bool, newest: Int64?, now: Int64) -> Int64? {
        if full && (!storeAnswered || remoteRelay) { return nil }
        return VaultActivity.refreshSince(newest: newest, now: now)
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

/// QueryVaultC's answer: {"events":[...]} or {"error":...}.
enum VaultStoreAnswer {
    /// The events, or nil for an error (not ready included) or a bad answer.
    static func rows(_ data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil,
              let events = object["events"] as? [[String: Any]] else { return nil }
        return events
    }

    /// The same answer decoded straight to events, in one pass (the Vault
    /// chips' reads: no dictionaries in between). Nil like `rows`. No
    /// signature check: the store kept only events it had verified.
    static func events<Event: Decodable>(_ data: Data, as _: Event.Type) -> [Event]? {
        guard let answer = try? JSONDecoder().decode(VaultStoreEvents<Event>.self, from: data),
              answer.error == nil else { return nil }
        return answer.events
    }
}

private struct VaultStoreEvents<Event: Decodable>: Decodable {
    let events: [Event]?
    let error: String?
}
