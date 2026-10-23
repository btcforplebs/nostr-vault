import Foundation

/// The Everyone switch (Global views without the Web of Trust filter) stays
/// locked until the account follows a few people: with almost no follows
/// there is no web to fall back to, and Everyone is where spam and sensitive
/// posts live. Someone who already turned Everyone on keeps it; the lock only
/// stops turning it on. Android's twin is TrustScopeLock.kt.
enum TrustScopeLock {
    static let followsNeeded = 5

    /// People in the follow list, each once, yourself not counted.
    static func followCount(_ follows: [String], me: String) -> Int {
        Set(follows.map { $0.lowercased() }).subtracting([me.lowercased()]).count
    }

    /// Follows still needed before Everyone unlocks; 0 when it is open.
    static func remaining(followCount: Int) -> Int {
        max(0, followsNeeded - followCount)
    }

    /// Whether turning Everyone on is refused now. Never while it is already
    /// on, so the setting an existing user chose is left alone.
    static func isLocked(followCount: Int, everyoneIsOn: Bool) -> Bool {
        !everyoneIsOn && remaining(followCount: followCount) > 0
    }

    /// "Follow 3 more people to unlock Everyone".
    static func progressText(followCount: Int) -> String {
        let left = remaining(followCount: followCount)
        guard left > 0 else { return "Everyone is unlocked" }
        return "Follow \(left) more \(left == 1 ? "person" : "people") to unlock Everyone"
    }
}
