import Foundation

/// Where the next DM catch-up from outside relays starts.
///
/// It used to be one timestamp for every account, moved to "now" whenever a
/// fetch ended, reached or not. Account B then started from account A's last
/// fetch and never got its older NIP-04 DMs, and opening the app offline moved
/// the mark past messages no relay had sent yet. Now each account has its
/// own, and a fetch moves it only when at least one relay finished answering
/// (EOSE). It moves to when the fetch started, not when it ended, so a
/// message published during the fetch is asked for again next time.
struct DMCatchUp: Equatable {
    static let legacyKey = "com.haven.dm.lastExternalFetchTimestamp"

    static func key(account: String) -> String { "\(legacyKey).\(account)" }

    let account: String
    let startedAt: Int64
    private(set) var relaysFinished = 0

    init(account: String, startedAt: Int64) {
        self.account = account
        self.startedAt = startedAt
    }

    /// A relay sent EOSE: it has answered everything it holds.
    mutating func relayFinished() { relaysFinished += 1 }

    /// The mark to save when the fetch is over.
    func nextMark(previous: Int64) -> Int64 {
        relaysFinished > 0 ? max(previous, startedAt) : previous
    }
}
