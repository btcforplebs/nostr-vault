import Foundation

/// Who told you about Nostr Vault, carried through setup.
///
/// - A profile link opened before setup is done (the website's "Open in Nostr
///   Vault", a scanned or tapped nostrvault.app/p/ link) has no profile to
///   open yet; it is kept here and the setup step starts with that person.
/// - The people picked in that step are followed once setup has stored the
///   key and the follow list can be read; until then they wait here, so a
///   relaunch mid-setup does not lose them.
struct SetupReferral {
    private let defaults: UserDefaults
    private static let referrerKey = "setupReferral.referrer"
    private static let followsKey = "setupReferral.follows"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The person a link opened before setup named, as hex.
    var pendingReferrer: String? {
        get { defaults.string(forKey: Self.referrerKey) }
        nonmutating set {
            if let hex = newValue?.lowercased(), hex.count == 64, hex.allSatisfy(\.isHexDigit) {
                defaults.set(hex, forKey: Self.referrerKey)
            } else {
                defaults.removeObject(forKey: Self.referrerKey)
            }
        }
    }

    /// The referrer first, then the people picked under them: who setup will
    /// follow. Hex, each once.
    var pendingFollows: [String] {
        get { defaults.stringArray(forKey: Self.followsKey) ?? [] }
        nonmutating set {
            var seen = Set<String>()
            let clean = newValue.map { $0.lowercased() }
                .filter { $0.count == 64 && $0.allSatisfy(\.isHexDigit) && seen.insert($0).inserted }
            if clean.isEmpty {
                defaults.removeObject(forKey: Self.followsKey)
            } else {
                defaults.set(clean, forKey: Self.followsKey)
            }
        }
    }

    /// Hands over the follows and forgets both: called once, as setup ends.
    func takeFollows() -> [String] {
        let follows = pendingFollows
        pendingFollows = []
        pendingReferrer = nil
        return follows
    }
}
