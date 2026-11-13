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
        let own = ConfigService.shared.allAccountHexes
        let visits = Self.lastVisits(account: account)
        var lit: Set<VaultMode> = []
        for mode in waiting {
            let dates = NostrService.shared.events.compactMap { event -> Int64? in
                guard VaultMode.listing(inboxKind: event.kind) == mode,
                      !own.contains(event.pubkey.lowercased()),
                      event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1].lowercased() == account })
                else { return nil }
                return event.created_at
            }
            if VaultNewsAccounts<VaultMode>.isNews(createdAt: dates, lastVisit: visits[mode.rawValue]) {
                lit.insert(mode)
            }
        }
        if !lit.isEmpty { newActivityModes.formUnion(lit) }
    }

    /// An account switch: the old account keeps its dot for when you come
    /// back, the new one shows its own.
    func switchNewsDot(from previous: String, to account: String) {
        let next = newsAccounts.switchAccount(from: previous, to: account,
                                              modes: newActivityModes, dmSeen: dmUnreadSeen)
        if newActivityModes != next.modes { newActivityModes = next.modes }
        if dmUnreadSeen != next.dmSeen { dmUnreadSeen = next.dmSeen }
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
