import Foundation

/// Every guided tutorial in the app. The raw value is the storage key, so
/// never rename one: a renamed tutorial shows again to everyone who saw it.
enum TutorialID: String, CaseIterable, Codable {
    case fillYourVault = "fill-your-vault"
    case feeds
    case vault
    case walletConnect = "wallet-connect"
    case pocketRelay = "pocket-relay"

    /// Fill your vault is about one account's follows, so a second account
    /// gets it again. The page tutorials teach the app, so one run covers
    /// every account on the device.
    var isPerAccount: Bool { self == .fillYourVault }

    /// Bump when a page changes enough that people who saw the old
    /// tutorial should see the new one once. A stored status from an older
    /// version reads as `notStarted`.
    var version: Int { 1 }
}

enum TutorialStatus: String, Codable {
    case notStarted, skipped, done
}

/// Where tutorial progress is kept. UserDefaults in the app; a dictionary
/// in tests.
protocol TutorialStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// The rules for when a tutorial may show, with no UI in it so they can be
/// tested on their own. `TutorialCenter` publishes the result to the app.
struct TutorialProgress {
    static let keyPrefix = "tutorial."

    let store: TutorialStore
    /// The one tutorial on screen, if any. Only one at a time.
    private(set) var active: TutorialID?
    /// Set once a tutorial has shown on its own this launch. A replay from
    /// Settings doesn't count: the person asked for it.
    private(set) var autoStartedThisLaunch = false

    init(store: TutorialStore) {
        self.store = store
    }

    static func key(_ id: TutorialID, account: String) -> String {
        id.isPerAccount ? "\(keyPrefix)\(id.rawValue).\(account)" : "\(keyPrefix)\(id.rawValue)"
    }

    /// Stored as "<status>@<version>", so a version bump reads as not started.
    func status(_ id: TutorialID, account: String) -> TutorialStatus {
        guard let raw = store.string(forKey: Self.key(id, account: account)) else { return .notStarted }
        let parts = raw.split(separator: "@", maxSplits: 1)
        guard parts.count == 2,
              let status = TutorialStatus(rawValue: String(parts[0])),
              Int(parts[1]) == id.version else { return .notStarted }
        return status
    }

    /// Whether `id` may show on its own right now: not seen at this version,
    /// nothing else on screen, nothing already shown this launch, and, for
    /// the page tutorials, Fill your vault finished or skipped first so a new
    /// account never gets two in a row.
    func isEligible(_ id: TutorialID, account: String) -> Bool {
        guard !account.isEmpty,
              active == nil,
              !autoStartedThisLaunch,
              status(id, account: account) == .notStarted else { return false }
        if id != .fillYourVault {
            return status(.fillYourVault, account: account) != .notStarted
        }
        return true
    }

    @discardableResult
    mutating func startIfEligible(_ id: TutorialID, account: String) -> Bool {
        guard isEligible(id, account: account) else { return false }
        active = id
        autoStartedThisLaunch = true
        return true
    }

    /// From Settings: shows `id` now, replacing whatever is on screen. Its
    /// saved status is left alone until it's finished or skipped again.
    mutating func replay(_ id: TutorialID) {
        active = id
    }

    mutating func finish(_ id: TutorialID, account: String) {
        close(id, as: .done, account: account)
    }

    mutating func skip(_ id: TutorialID, account: String) {
        close(id, as: .skipped, account: account)
    }

    /// Forget every tutorial's status for this account (and the device-wide
    /// ones), so each shows again on its page.
    mutating func resetAll(account: String) {
        for id in TutorialID.allCases {
            store.set(nil, forKey: Self.key(id, account: account))
        }
        active = nil
    }

    private mutating func close(_ id: TutorialID, as status: TutorialStatus, account: String) {
        if !account.isEmpty {
            store.set("\(status.rawValue)@\(id.version)", forKey: Self.key(id, account: account))
        }
        if active == id { active = nil }
    }
}
