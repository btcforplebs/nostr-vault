import Foundation

/// When a waiting post (`QueuedMediaPost`) is tried again, and when it stops
/// trying by itself.
///
/// Each try uploads the whole file to every mirror. A fixed one-minute retry
/// that never gave up turned one photo a server would not take into gigabytes
/// a day on a phone's data plan. Now the wait doubles from one minute up to six
/// hours, the post stops after `maxAutomaticAttempts`, and a server that says
/// no to the file itself (most 4xx) stops it at once. Either way the post stays
/// saved and the user can send it again from Settings → Media Servers.
enum MediaPostRetry {
    static let firstDelay: TimeInterval = 60
    static let maxDelay: TimeInterval = 6 * 60 * 60
    static let maxAutomaticAttempts = 10

    /// The wait after the `attempts`-th try: 1, 2, 4 … minutes, at most six hours.
    static func delay(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let doublings = min(attempts - 1, 20)
        return min(firstDelay * pow(2, Double(doublings)), maxDelay)
    }

    /// An HTTP answer that will be the same next time: the server refuses this
    /// file (too big, wrong type, payment or login needed, forbidden). 408 and
    /// 429 are the server being busy, so they are worth another try.
    static func isPermanentRefusal(status: Int) -> Bool {
        (400...499).contains(status) && status != 408 && status != 429
    }

    /// True when every mirror tried answered with a permanent refusal.
    /// `statuses` holds one entry per mirror that answered with an HTTP code;
    /// a mirror that never answered is missing from it and keeps the post going.
    static func allRefused(mirrors: [String], statuses: [String: Int]) -> Bool {
        guard !mirrors.isEmpty else { return false }
        return mirrors.allSatisfy { mirror in
            statuses[mirror].map(isPermanentRefusal(status:)) ?? false
        }
    }

    /// The posts to try this round, oldest first: due now and written by the
    /// active account. Another account's post is skipped, not tried: it used
    /// to count as a failed try, which ends the round, so one post held for
    /// another account stopped every post behind it from ever being sent.
    static func dueIDs(in posts: [QueuedMediaPost], at now: Date, activeAccount: String) -> [String] {
        posts.filter { $0.accountNpub == activeAccount && $0.isDue(at: now) }.map(\.id)
    }
}

extension QueuedMediaPost {
    /// What the Media servers page says about a post every server refused:
    /// the HTTP code and, when the server gave one, its own reason.
    var refusalLine: String? {
        guard let status = refusedStatus else { return nil }
        let why = refusedReason.map { ": \($0)" } ?? ""
        return "Your media servers refused this file (HTTP \(status)\(why)). Change servers below, then tap Try sending now."
    }

    /// The post stopped trying by itself and waits for the user.
    var needsUser: Bool {
        refusedStatus != nil || attempts >= MediaPostRetry.maxAutomaticAttempts
    }

    /// When the next automatic try may run; nil when there is none.
    var nextAttempt: Date? {
        guard !needsUser else { return nil }
        guard let lastAttempt else { return createdAt }
        return lastAttempt.addingTimeInterval(MediaPostRetry.delay(afterAttempts: attempts))
    }

    func isDue(at now: Date) -> Bool {
        guard let nextAttempt else { return false }
        return now >= nextAttempt
    }

    /// The user asked to send it again: a fresh start, as if just queued.
    mutating func resetForUserRetry() {
        attempts = 0
        refusedStatus = nil
        refusedReason = nil
    }
}
