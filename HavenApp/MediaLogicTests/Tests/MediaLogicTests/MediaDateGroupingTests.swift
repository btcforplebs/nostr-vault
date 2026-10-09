import XCTest
@testable import MediaLogic

/// `now` is fixed at Wednesday 2026-09-09 12:00 UTC. With a Sunday-start week
/// that puts the current week at Sun 2026-09-06 through Sat 2026-09-12, which
/// is what the "This Week" cases below rely on.
final class MediaDateGroupingTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1
        return cal
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 9, 9) }

    private func key(_ d: Date) -> String {
        MediaDateGrouping.bucketKey(for: d, now: now, calendar: calendar)
    }

    // MARK: - Buckets

    func testTodayIsToday() {
        XCTAssertEqual(key(date(2026, 9, 9, 8)), "Today")
        XCTAssertEqual(key(date(2026, 9, 9, 23)), "Today")
    }

    func testEarlierInTheSameWeekIsThisWeek() {
        // Monday and Sunday of the week containing `now`.
        XCTAssertEqual(key(date(2026, 9, 7)), "This Week")
        XCTAssertEqual(key(date(2026, 9, 6)), "This Week")
    }

    /// The regression this guards: a "last seven days" rule would call
    /// 2026-09-02 this week. It is the previous calendar week, so it is not.
    func testEarlierInTheMonthButPreviousWeekIsThisMonth() {
        XCTAssertEqual(key(date(2026, 9, 2)), "This Month")
        XCTAssertEqual(key(date(2026, 9, 1)), "This Month")
    }

    func testEarlierMonthsFallOutOfTheRelativeBuckets() {
        let august = key(date(2026, 8, 15))
        XCTAssertFalse(["Today", "This Week", "This Month"].contains(august))
        // Two dates in the same month share one heading...
        XCTAssertEqual(august, key(date(2026, 8, 2)))
        // ...and the same month in a different year does not, or a year-old
        // photo would file itself under this year's heading.
        XCTAssertNotEqual(august, key(date(2025, 8, 15)))
    }

    // MARK: - Runs

    private struct Item { let name: String; let at: Date }

    private func runs(_ items: [Item]) -> [(title: String, items: [Item])] {
        MediaDateGrouping.runs(of: items, date: \.at, now: now, calendar: calendar)
    }

    func testEmptyInputProducesNoRuns() {
        XCTAssertTrue(runs([]).isEmpty)
    }

    func testConsecutiveItemsInOneBucketBecomeOneRun() {
        let result = runs([
            Item(name: "a", at: date(2026, 9, 9, 9)),
            Item(name: "b", at: date(2026, 9, 9, 8)),
            Item(name: "c", at: date(2026, 9, 7)),
        ])
        XCTAssertEqual(result.map(\.title), ["Today", "This Week"])
        XCTAssertEqual(result[0].items.map(\.name), ["a", "b"])
        XCTAssertEqual(result[1].items.map(\.name), ["c"])
    }

    /// Order in, order out — the grouping must never re-sort. Oldest-first is
    /// the mirror of newest-first, with Today last.
    func testRunOrderFollowsTheInputOrder() {
        let newestFirst = runs([
            Item(name: "today", at: date(2026, 9, 9)),
            Item(name: "week", at: date(2026, 9, 7)),
            Item(name: "month", at: date(2026, 9, 1)),
        ])
        XCTAssertEqual(newestFirst.map(\.title), ["Today", "This Week", "This Month"])

        let oldestFirst = runs([
            Item(name: "month", at: date(2026, 9, 1)),
            Item(name: "week", at: date(2026, 9, 7)),
            Item(name: "today", at: date(2026, 9, 9)),
        ])
        XCTAssertEqual(oldestFirst.map(\.title), ["This Month", "This Week", "Today"])
    }

    /// Documents the contract the gallery relies on: headings are only
    /// meaningful over a date-sorted list. Unsorted input repeats them, which
    /// is why the view groups only under the date sorts.
    func testUnsortedInputRepeatsHeadings() {
        let result = runs([
            Item(name: "a", at: date(2026, 9, 9)),
            Item(name: "b", at: date(2026, 9, 1)),
            Item(name: "c", at: date(2026, 9, 9)),
        ])
        XCTAssertEqual(result.map(\.title), ["Today", "This Month", "Today"])
    }

    /// Runs format each month once and reuse it; the reused title must still
    /// be what `bucketKey` gives that item, including the same month a year
    /// apart.
    func testRunTitlesMatchBucketKeyAcrossYears() {
        let dates = [date(2026, 3, 20), date(2026, 3, 2), date(2025, 3, 20), date(2025, 3, 2), date(2024, 11, 5)]
        let result = runs(dates.enumerated().map { Item(name: "\($0.offset)", at: $0.element) })
        XCTAssertEqual(result.map(\.title), [key(dates[0]), key(dates[2]), key(dates[4])])
        XCTAssertEqual(result.map(\.items.count), [2, 2, 1])
        XCTAssertNotEqual(result[0].title, result[1].title)
    }
}
