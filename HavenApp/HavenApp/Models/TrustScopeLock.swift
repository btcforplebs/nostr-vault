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

    /// Whether a hashtag view (the Hashtags feed or a single #tag page) opens
    /// screened (`TopicFeedFilter`) instead of filtered to your web. True
    /// while Everyone is locked, not only with an empty web: with 1-4 follows
    /// the web is tiny, so a tag showed nearly nothing while Everyone, the
    /// only way out, stayed locked until 5 follows, and the tags are where a
    /// new account finds those 5 (Logen 2026-11-05,
    /// RESEARCH/NV_NEW_USER_HASHTAG_LOOP_2026_11_05.md). Everyone on: never.
    static func hashtagsScreened(everyoneIsOn: Bool, followCount: Int, noWebYet: Bool) -> Bool {
        guard !everyoneIsOn else { return false }
        return noWebYet || isLocked(followCount: followCount, everyoneIsOn: false)
    }

    /// "Follow 3 more people to unlock Everyone".
    static func progressText(followCount: Int) -> String {
        let left = remaining(followCount: followCount)
        guard left > 0 else { return "Everyone is unlocked" }
        return "Follow \(left) more \(left == 1 ? "person" : "people") to unlock Everyone"
    }
}
