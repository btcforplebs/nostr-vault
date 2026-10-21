import SwiftUI

extension FeedNoteRow {
    func shortKey(_ key: String) -> String {
        guard key.count >= 12 else { return key }
        return "npub…" + String(key.suffix(6))
    }

    func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<60:         return "now"
        case ..<3600:       return "\(Int(diff / 60))m"
        case ..<86400:      return "\(Int(diff / 3600))h"
        case ..<604800:     return "\(Int(diff / 86400))d"
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                ? "MMM d" : "MMM d, yyyy"
            return fmt.string(from: date)
        }
    }
}
