import Foundation

/// When to ask relays for profiles that changed, and what to ask for.
///
/// Profiles are cached on the device for good, and the app only re-asked for
/// one when you opened it, so a follow who changed their picture kept the old
/// one indefinitely. Once a day the app asks for just the profiles (kind 0)
/// newer than its last check: relays answer with the few that changed, not
/// with everyone.
enum ProfileRefreshPlan {
    static let interval: TimeInterval = 24 * 60 * 60
    /// Relay clocks drift and events reach relays late: look back an hour
    /// past the last check so a change made just before it isn't missed.
    static let overlap: TimeInterval = 60 * 60
    /// Authors per filter; relays reject very large filters.
    static let batchSize = 250

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The `since` for this check: an hour before the last one, or nil the
    /// first time, which asks for every profile once.
    static func since(lastCheck: Date?) -> Int64? {
        lastCheck.map { Int64($0.timeIntervalSince1970 - overlap) }
    }

    /// One kind-0 filter per `batchSize` authors, duplicates and blanks dropped.
    static func filters(for pubkeys: [String], since: Int64?) -> [[String: Any]] {
        let authors = Array(Set(pubkeys.filter { !$0.isEmpty })).sorted()
        return stride(from: 0, to: authors.count, by: batchSize).map { start in
            var filter: [String: Any] = [
                "kinds": [0],
                "authors": Array(authors[start..<min(start + batchSize, authors.count)]),
            ]
            if let since { filter["since"] = since }
            return filter
        }
    }
}
