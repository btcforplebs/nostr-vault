import Foundation

// MARK: - Zaps today
//
// The counting rules behind the Lock Screen widget's "Zaps today", apart from
// the relay so they can be tested (see HavenApp/MediaLogicTests). The app half
// that asks the relay is NVZapsTodayCounter; Android's twin is ZapsToday in
// service/ZapsTodayCounter.kt, and the two follow the same rules.

enum NVZapsToday {
    static let receiptKind = 9735

    /// One relay answer's worth; a day with more shows this many.
    static let limit = 500

    /// A zap receipt reduced to what counting needs.
    struct Receipt: Equatable {
        var id: String
        var publisher: String
        var recipients: [String]
        var createdAt: Int

        init(id: String, publisher: String, recipients: [String], createdAt: Int) {
            self.id = id
            self.publisher = publisher
            self.recipients = recipients
            self.createdAt = createdAt
        }

        /// Nil for anything that is not a well-formed kind 9735 event.
        init?(event: [String: Any]) {
            guard (event["kind"] as? Int) == NVZapsToday.receiptKind,
                  let id = event["id"] as? String,
                  let publisher = event["pubkey"] as? String,
                  let createdAt = (event["created_at"] as? NSNumber)?.intValue else { return nil }
            let tags = event["tags"] as? [[String]] ?? []
            self.init(id: id, publisher: publisher,
                      recipients: tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1] : nil },
                      createdAt: createdAt)
        }
    }

    /// Local midnight at or before `date`.
    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Receipts made out to `me` at or after `since` (epoch seconds), each counted once.
    static func count(_ receipts: [Receipt], me: String, since: Int) -> Int {
        let me = me.lowercased()
        let ids = receipts
            .filter { $0.createdAt >= since && $0.recipients.contains { $0.lowercased() == me } }
            .map(\.id)
        return Set(ids).count
    }

    /// What the widget shows at `now` for a count made on the day that started
    /// at `dayStart`: the count on that same day, 0 once the day has changed,
    /// so yesterday's number never shows after midnight.
    static func shown(count: Int, dayStart: Date?, at now: Date, calendar: Calendar = .current) -> Int {
        guard let dayStart, dayStart == startOfDay(now, calendar: calendar) else { return 0 }
        return count
    }
}
