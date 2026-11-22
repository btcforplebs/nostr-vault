import Foundation

/// The feed's first card for a new account that came through an invite
/// (setup screens r3, step 5): who brought you in, with Wave back. Set as
/// setup ends; shown on that account's feed for its first day, until waved
/// at or closed. Pure Foundation so MediaLogicTests can test it.
struct InviterWelcome {
    private let defaults: UserDefaults
    private static let key = "inviterWelcome"
    /// How long the card stays up.
    static let lifetime: TimeInterval = 24 * 3600

    struct Entry: Codable, Equatable {
        /// The new account (hex).
        let account: String
        /// Who invited it (hex).
        let inviter: String
        let since: Date
        var waved = false
        var closed = false
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var entry: Entry? {
        get { defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    /// Setup ended for `account` with `inviter` first in its follows.
    func start(account: String, inviter: String?, now: Date = Date()) {
        let account = account.lowercased()
        guard let inviter = inviter?.lowercased(), Self.isHex(inviter), Self.isHex(account), inviter != account else {
            entry = nil
            return
        }
        entry = Entry(account: account, inviter: inviter, since: now)
    }

    /// The inviter to show on `account`'s feed now, if any.
    func inviter(for account: String, now: Date = Date()) -> String? {
        guard let entry, entry.account == account.lowercased(), !entry.closed, !entry.waved,
              now.timeIntervalSince(entry.since) < Self.lifetime, now >= entry.since else { return nil }
        return entry.inviter
    }

    func markWaved() { if var e = entry { e.waved = true; entry = e } }
    func close() { if var e = entry { e.closed = true; entry = e } }

    /// The wave: a short public note that mentions the inviter.
    static func waveContent(inviterNpub: String) -> String { "👋 nostr:\(inviterNpub)" }
    static func waveTags(inviter: String) -> [[String]] { [["p", inviter.lowercased()]] }

    private static func isHex(_ s: String) -> Bool { s.count == 64 && s.allSatisfy(\.isHexDigit) }
}
