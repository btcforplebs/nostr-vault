import Foundation

/// Follow Distance per account (Logen 2026-11-22: "Follow Distance has to be
/// per account, so we don't mash mute lists together").
///
/// Where each account's value lives:
/// - The first account's is the pair this config always had
///   (`chatRelayWotDepth`, `chatRelayMinFollowers`). It still goes to the
///   relay as WOT_DEPTH / WOT_MINIMUM_FOLLOWERS and to your other devices as
///   the mesh's `wot_depth`, so an older build, and a device that has not
///   updated yet, keep working with it.
/// - Every other account's is its entry in `reachPerAccount`, handed to the
///   relay in `account_reach.json`. An account with no entry yet uses the
///   first account's value: that is what every account ran on before, so
///   nothing has to be converted.
///
/// Changing the first account's value first gives every other account its
/// own entry at the old value, so one account's change never moves another.
extension HavenConfig {
    /// The file the relay reads each account's reach from (ACCOUNT_REACH_FILE).
    static let accountReachFile = "account_reach.json"

    /// The account the app is showing: the first account when none is picked.
    var reachAccountNpub: String {
        let active = activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        return active.isEmpty ? ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines) : active
    }

    private var firstAccountReach: AccountReach {
        AccountReach(depth: chatRelayWotDepth, minFollowers: chatRelayMinFollowers).clamped
    }

    private func isFirstAccount(_ npub: String) -> Bool {
        npub.isEmpty || npub == ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `npub`'s own reach.
    func reach(for raw: String) -> AccountReach {
        let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFirstAccount(npub) { return firstAccountReach }
        return reachPerAccount[npub]?.clamped ?? firstAccountReach
    }

    /// Sets `npub`'s own reach and nobody else's.
    mutating func setReach(_ reach: AccountReach, for raw: String) {
        let npub = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = reach.clamped
        guard isFirstAccount(npub) else {
            reachPerAccount[npub] = value
            return
        }
        guard value != firstAccountReach else { return }
        keepOtherAccountsReach()
        chatRelayWotDepth = value.depth
        chatRelayMinFollowers = value.minFollowers
    }

    /// Gives every other account that has no entry yet its own, at the value
    /// it runs on now. Call before the first account's value changes (a
    /// stepper here, or settings copied from another of your devices).
    mutating func keepOtherAccountsReach() {
        let current = firstAccountReach
        for npub in vaultWhitelistNpubs where reachPerAccount[npub] == nil {
            reachPerAccount[npub] = current
        }
    }

    /// What `account_reach.json` holds: the entry of every other account
    /// still on this device. The first account is left out (it is the
    /// relay's WOT_DEPTH), and so is a removed account.
    var relayAccountReach: [String: AccountReach] {
        var out: [String: AccountReach] = [:]
        for npub in vaultWhitelistNpubs {
            if let entry = reachPerAccount[npub] { out[npub] = entry.clamped }
        }
        return out
    }

    /// The file's bytes: `{"v":1,"accounts":{"npub1…":{"depth":2,"min_followers":3}}}`.
    static func accountReachFileData(_ reach: [String: AccountReach]) -> Data? {
        let accounts = reach.mapValues { ["depth": $0.depth, "min_followers": $0.minFollowers] }
        return try? JSONSerialization.data(withJSONObject: ["v": 1, "accounts": accounts],
                                           options: [.sortedKeys])
    }

    /// Writes `account_reach.json` beside the relay. Every start writes it,
    /// with no entries too, so a stale file never outlives its accounts.
    static func writeAccountReachFile(_ reach: [String: AccountReach], under dir: URL) {
        guard let data = accountReachFileData(reach) else { return }
        try? data.write(to: dir.appendingPathComponent(accountReachFile), options: .atomic)
    }
}
