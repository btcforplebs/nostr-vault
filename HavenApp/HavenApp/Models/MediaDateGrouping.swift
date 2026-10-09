import Foundation

/// Groups an already-sorted list into the date headings the media gallery
/// shows: Today / This Week / This Month / month-and-year.
///
/// Generic over the element so this stays pure Foundation and can be tested
/// without pulling in the app's view layer.
enum MediaDateGrouping {

    /// The heading a date belongs under.
    ///
    /// "This Week" is the calendar week containing `now`, not the last seven
    /// days — a Monday should not sit under "This Week" when read on Sunday of
    /// the following week. Same for "This Month".
    static func bucketKey(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        var titles = MonthTitles(now: now, calendar: calendar)
        return bucketKey(for: date, now: now, calendar: calendar, monthTitles: &titles)
    }

    private static func bucketKey(for date: Date, now: Date, calendar: Calendar,
                                  monthTitles: inout MonthTitles) -> String {
        // Not `isDateInToday`: that compares against the system clock and would
        // ignore an injected `now`, which is exactly what the tests pin down.
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This Week" }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
        return monthTitles.title(for: date)
    }

    /// Month headings for one grouping pass. Building a `DateFormatter` per
    /// item was the cost of the Media tab redraw, so each month is formatted
    /// once and the two formatters are made once.
    private struct MonthTitles {
        let now: Date
        let calendar: Calendar
        private var cache: [Int: String] = [:]
        private var thisYear: DateFormatter?
        private var otherYears: DateFormatter?

        init(now: Date, calendar: Calendar) {
            self.now = now
            self.calendar = calendar
        }

        mutating func title(for date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month], from: date)
            let key = (parts.year ?? 0) * 12 + (parts.month ?? 0)
            if let hit = cache[key] { return hit }
            // Within the current year the year is noise; older media needs it
            // to be unambiguous.
            let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
            let formatter: DateFormatter
            if sameYear {
                if thisYear == nil { thisYear = Self.formatter("MMMM", calendar: calendar) }
                formatter = thisYear!
            } else {
                if otherYears == nil { otherYears = Self.formatter("MMMM yyyy", calendar: calendar) }
                formatter = otherYears!
            }
            let title = formatter.string(from: date)
            cache[key] = title
            return title
        }

        private static func formatter(_ template: String, calendar: Calendar) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
    }

    /// Splits `items` into consecutive runs that share a heading.
    ///
    /// Walks the list in the order given and starts a new run whenever the
    /// heading changes, so the caller's sort direction is preserved — newest
    /// first opens with Today, oldest first closes with it. Never reorders.
    /// A list that is not sorted by date will produce repeated headings, which
    /// is why the caller only groups under a date sort.
    static func runs<Element>(of items: [Element],
                              date: (Element) -> Date,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> [(title: String, items: [Element])] {
        var runs: [(title: String, items: [Element])] = []
        var monthTitles = MonthTitles(now: now, calendar: calendar)

        for item in items {
            let key = bucketKey(for: date(item), now: now, calendar: calendar, monthTitles: &monthTitles)
            if runs.last?.title == key {
                runs[runs.count - 1].items.append(item)
            } else {
                runs.append((title: key, items: [item]))
            }
        }

        return runs
    }
}
