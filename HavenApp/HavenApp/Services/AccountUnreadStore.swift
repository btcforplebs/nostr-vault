import Foundation

/// Keeps `AccountUnread` across launches and publishes it to the account
/// switchers. Fed by the relay's NOTIFY markers (RelayProcessManager), emptied
/// by the Vault list (`activityVisit`).
@MainActor
final class AccountUnreadStore: ObservableObject {
    static let shared = AccountUnreadStore()

    @Published private(set) var state: AccountUnread

    private let defaults: UserDefaults
    private static let key = "accountUnreadIds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = AccountUnread(ids: defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:])
    }

    func record(markers: [String], rules: AccountUnread.ListRules = .showsAll) {
        var next = state
        var changed = false
        for body in markers where next.record(body, rules: rules) { changed = true }
        if changed { save(next) }
    }

    func markSeen(hex: String) {
        var next = state
        if next.markSeen(hex) { save(next) }
    }

    /// An account's Vault list was viewed: its seen mark moves to `now` and
    /// its count empties, together. The Vault list and the Vault tab's
    /// account chips both clear through here. Returns the mark it
    /// replaced (0 for a first visit).
    @discardableResult
    func markVaultSeen(hex: String, at now: TimeInterval = Date().timeIntervalSince1970) -> TimeInterval {
        let key = AccountUnread.vaultSeenKey(hex)
        let last = defaults.double(forKey: key)
        defaults.set(now, forKey: key)
        markSeen(hex: hex)
        return last
    }

    /// The count for an account row, by npub.
    func count(npub: String) -> Int {
        guard let hex = Bech32.decode(npub)?.hexString else { return 0 }
        return state.count(for: hex)
    }

    /// The avatar dot: another signed-in account has news. `npubs` is every
    /// account on the device, `activeHex` the one in use.
    func othersHaveUnread(npubs: [String], activeHex: String) -> Bool {
        state.othersHaveUnread(accounts: npubs.compactMap { Bech32.decode($0)?.hexString }, active: activeHex)
    }

    private func save(_ next: AccountUnread) {
        state = next
        defaults.set(next.ids, forKey: Self.key)
    }
}
