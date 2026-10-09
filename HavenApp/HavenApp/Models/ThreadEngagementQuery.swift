import Foundation

/// The relay requests behind the note detail view's Thread Stats toggle.
///
/// A relay applies `limit` per filter, so a single filter over every note in
/// a thread shares one budget between all of them: one busy note fills it and
/// the rest come back short or empty. Splitting the thread into small batches
/// gives each batch its own budget.
enum ThreadEngagementQuery {
    /// Notes per request. Small enough that one popular note can't starve
    /// the others in its batch of much.
    static let batchSize = 10
    /// Events per request, per relay.
    static let limit = 500
    /// Reposts, reactions, zap receipts.
    static let kinds = [6, 7, 9735]

    struct Request: Equatable {
        let subscriptionId: String
        let noteIds: [String]

        var filter: [String: Any] {
            ["kinds": ThreadEngagementQuery.kinds, "#e": noteIds, "limit": ThreadEngagementQuery.limit]
        }
    }

    /// One request per batch of `noteIds`, in a stable order so the same
    /// thread always splits the same way.
    static func requests(for noteIds: some Collection<String>, subscriptionPrefix: String) -> [Request] {
        let sorted = Array(Set(noteIds)).sorted()
        return stride(from: 0, to: sorted.count, by: batchSize).enumerated().map { index, start in
            Request(
                subscriptionId: "\(subscriptionPrefix)-\(index)",
                noteIds: Array(sorted[start..<min(start + batchSize, sorted.count)])
            )
        }
    }
}
