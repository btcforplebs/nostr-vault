import Foundation

// MARK: - On this day, for the widget
//
// The On this day home screen widget (Logen, 2026-11-04): the user's own notes
// from today's date one and two years ago, as Your space's On this day panel
// shows them (Models/OnThisDay.swift). The app reads them from its own vault
// and hands them over in the widget snapshot; the widget never fetches.
//
// Pure and free of SwiftUI so MediaLogicTests can run it.

struct NVOnThisDaySnapshot: Codable, Equatable {
    /// Local midnight of the day these notes were read for. On any other day
    /// they are yesterday's memories, so the widget shows none.
    var dayStart: Date
    var years: [Year]

    struct Year: Codable, Equatable {
        /// 1 or 2: how many years back.
        var years: Int
        var notes: [Note]
    }

    struct Note: Codable, Equatable, Identifiable {
        var id: String
        /// One display line, already flattened by the app (OnThisDay.lineText).
        var text: String
        var createdAt: Date
    }

    /// The years with notes, as of `date`; none once the day they were read for is over.
    func shown(at date: Date, calendar: Calendar = .current) -> [Year] {
        guard calendar.isDate(dayStart, inSameDayAs: date) else { return [] }
        return years.filter { !$0.notes.isEmpty }
    }

    /// Every shown note with how many years back it is, in order (1 year ago first, oldest of the day first).
    func rows(at date: Date, calendar: Calendar = .current) -> [(years: Int, note: Note)] {
        shown(at: date, calendar: calendar).flatMap { y in y.notes.map { (y.years, $0) } }
    }

    /// "1 year ago", "2 years ago".
    static func yearsText(_ n: Int) -> String { n == 1 ? "1 year ago" : "\(n) years ago" }
}
