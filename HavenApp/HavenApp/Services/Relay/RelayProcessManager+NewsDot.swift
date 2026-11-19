import Foundation

/// The Vault tab's news dot, one per account, lit only for news (Logen
/// 2026-11-13: "on return to the app the Vault tab button is red").
///
/// The relay logs "new … in your inbox" for every event from others it
/// stores, and on return it stores the whole catch-up, including likes you
/// already saw on another device. So a landed line only proposes a list; it
/// lights when an event from someone else, tagging the account on screen and
/// dated after that account's last visit to the list, is actually in memory.
/// Rules in VaultNewsAccounts.
extension RelayProcessManager {
    /// When the relay's line is written the event is still on its way over the
    /// socket: look for it after these delays.
    static let newsChecks: [TimeInterval] = [1.5, 5]

    /// Lists the relay just stored something in. Lit once their event is
    /// found and is news; never lit by an old one.
    func proposeNews(_ landed: Set<VaultMode>) {
        let pending = landed.subtracting(newActivityModes)
        guard !pending.isEmpty else { return }
        let account = ConfigService.shared.activeAccountHexPubkey.lowercased()
        for delay in Self.newsChecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.lightNews(pending, account: account)
            }
        }
    }

    private func lightNews(_ modes: Set<VaultMode>, account: String) {
        // Switched away meanwhile: that account's lists aren't on this dot now.
        guard ConfigService.shared.activeAccountHexPubkey.lowercased() == account else { return }
        let waiting = modes.subtracting(newActivityModes)
        guard !waiting.isEmpty else { return }
        // Nothing reads the inbox into memory yet (the Vault tab not opened
        // since launch): the event can't be looked at, so the line decides.
        let inbox = ConfigService.shared.config.nostrURL + "/inbox"
        guard NostrService.shared.activeSubscriptions[inbox] != nil else {
            newActivityModes.formUnion(waiting)
            return
        }
        // The scan walks every event in memory and its tags, so it runs off
        // the main thread: on the main thread it cost scroll frames each time
        // a notification arrived. The array is copied as a value here.
        let own = ConfigService.shared.allAccountHexes
        let events = NostrService.shared.events
        Task.detached(priority: .utility) { [weak self] in
            let newest = Self.newestFromOthers(in: events, modes: waiting, account: account, own: own)
            guard !newest.isEmpty else { return }
            await self?.lightNews(newest: newest, account: account)
        }
    }

    /// Back on the main thread: lit only if still on this account, and against
    /// the visit dates as they are now, so a list opened during the scan stays
    /// dark.
    private func lightNews(newest: [VaultMode: Int64], account: String) {
        guard ConfigService.shared.activeAccountHexPubkey.lowercased() == account else { return }
        let visits = Self.lastVisits(account: account)
        let lit = Set(newest.compactMap { mode, date in
            VaultNewsAccounts<VaultMode>.isNews(createdAt: [date], lastVisit: visits[mode.rawValue]) ? mode : nil
        })
        let waiting = lit.subtracting(newActivityModes)
        if !waiting.isEmpty { newActivityModes.formUnion(waiting) }
    }

    /// The newest event from someone else tagging `account`, per list in
    /// `modes`; a list with none is left out. For the background scan.
    nonisolated static func newestFromOthers(in events: [NostrEvent], modes: Set<VaultMode>,
                                             account: String, own: Set<String>) -> [VaultMode: Int64] {
        VaultNewsAccounts<VaultMode>.newest(
            in: events, modes: modes,
            listing: { VaultMode.listing(inboxKind: $0.kind) },
            counts: { VaultNewsAccounts<VaultMode>.isFromOthersTagging(pubkey: $0.pubkey, tags: $0.tags,
                                                                       account: account, own: own) },
            createdAt: { $0.created_at })
    }

    /// An account switch: the old account keeps its dot for when you come
    /// back, the new one shows its own.
    func switchNewsDot(from previous: String, to account: String) {
        let next = newsAccounts.switchAccount(from: previous, to: account,
                                              modes: newActivityModes, dmSeen: dmUnreadSeen)
        if newActivityModes != next.modes { newActivityModes = next.modes }
        // The DM seen count is saved per account and loaded on the switch by
        // VaultNewsState; the ledger's in-memory copy would reset it to 0.
    }

    // MARK: - Last visit per account and list

    private static func visitsKey(_ account: String) -> String { "vaultNewsLastVisit.\(account.lowercased())" }

    /// Unix seconds of each list's last visit, by `VaultMode.rawValue`.
    static func lastVisits(account: String) -> [String: Int64] {
        let raw = UserDefaults.standard.dictionary(forKey: visitsKey(account)) as? [String: Double] ?? [:]
        return raw.mapValues { Int64($0) }
    }

    /// `modes` were on screen for the active account just now.
    func recordVisit(_ modes: [VaultMode]) {
        let account = ConfigService.shared.activeAccountHexPubkey
        guard !account.isEmpty else { return }
        let key = Self.visitsKey(account)
        var raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for mode in modes { raw[mode.rawValue] = now }
        UserDefaults.standard.set(raw, forKey: key)
    }
}
