import Foundation

/// The import tour's plain-words headline, read from what
/// `RelayProcessManager` reports (`importStatusMessage`, set by
/// `RelayLogParser`). The import gives no running count, but the notes part
/// does say which dates it's on, so the headline can say how far back it got.
struct ImportTourStage: Equatable {
    /// "Saving your notes from Mar 2024…"
    let text: String
    /// 1 connect, 2 notes, 3 replies and mentions, 4 done.
    let step: Int
    static let stepCount = 4

    init(text: String, step: Int) {
        self.text = text
        self.step = step
    }

    init(statusMessage: String, completed: Bool) {
        if completed {
            self = ImportTourStage(text: "Done. Your notes are home.", step: 4)
        } else if statusMessage.hasPrefix("Looking through notes") {
            if let month = Self.month(in: statusMessage) {
                self = ImportTourStage(text: "Looking through \(month)…", step: 2)
            } else {
                self = ImportTourStage(text: "Looking through your history…", step: 2)
            }
        } else if statusMessage.hasPrefix("Found notes") {
            if let month = Self.month(in: statusMessage) {
                self = ImportTourStage(text: "Saving your notes from \(month)…", step: 2)
            } else {
                self = ImportTourStage(text: "Saving your notes…", step: 2)
            }
        } else if statusMessage.hasPrefix("Importing tagged notes") {
            self = ImportTourStage(text: "Saving replies and mentions of you…", step: 3)
        } else if statusMessage.contains("Web of Trust") {
            self = ImportTourStage(text: "Finding the people you follow…", step: 1)
        } else {
            self = ImportTourStage(text: "Connecting to your relays…", step: 1)
        }
    }

    /// "Found notes from 2024-03-05T…" → "Mar 2024".
    static func month(in message: String) -> String? {
        guard let range = message.range(of: "from ") else { return nil }
        let datePart = message[range.upperBound...].prefix(10)
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard datePart.count == 10, let date = parser.date(from: String(datePart)) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "MMM yyyy"
        return out.string(from: date)
    }
}
