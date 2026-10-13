import XCTest
@testable import MediaLogic

/// "Zaps today" for the Lock Screen widget: since local midnight, for you,
/// each receipt once, and 0 once the day has changed.
final class NVZapsTodayTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private func receipt(_ id: String, _ createdAt: Int, _ p: String...) -> NVZapsToday.Receipt {
        .init(id: id, publisher: String(repeating: "c", count: 64), recipients: p, createdAt: createdAt)
    }

    func testTheDayStartsAtLocalMidnight() {
        XCTAssertEqual(NVZapsToday.startOfDay(at(2026, 10, 13, 22, 44), calendar: calendar), at(2026, 10, 13))
        XCTAssertEqual(NVZapsToday.startOfDay(at(2026, 10, 14, 0, 1), calendar: calendar), at(2026, 10, 14))
    }

    func testTheDayFollowsTheClockAcrossADaylightSavingChange() {
        // Clocks go back on 2026-11-01 in New York: that day is 25 hours long.
        XCTAssertEqual(NVZapsToday.startOfDay(at(2026, 11, 1, 23, 30), calendar: calendar), at(2026, 11, 1))
    }

    func testCountsOnlyTodaysReceiptsToYouEachOnce() {
        let midnight = Int(at(2026, 10, 13).timeIntervalSince1970)
        let receipts = [
            receipt("1", midnight, me),                 // at midnight: today
            receipt("2", midnight + 3_600, me.uppercased()),
            receipt("2", midnight + 3_600, me),         // the same receipt from the second relay path
            receipt("3", midnight - 1, me),             // yesterday
            receipt("4", midnight + 60, other),         // someone else's
            receipt("5", midnight + 90, other, me),     // names you among others
        ]
        XCTAssertEqual(NVZapsToday.count(receipts, me: me, since: midnight), 3)
    }

    func testMidnightResetsTheCount() {
        let day1 = at(2026, 10, 13), day2 = at(2026, 10, 14)
        let receipts = [receipt("1", Int(day1.timeIntervalSince1970) + 100, me),
                        receipt("2", Int(day1.timeIntervalSince1970) + 80_000, me)]
        XCTAssertEqual(NVZapsToday.count(receipts, me: me, since: Int(day1.timeIntervalSince1970)), 2)
        XCTAssertEqual(NVZapsToday.count(receipts, me: me, since: Int(day2.timeIntervalSince1970)), 0)
    }

    func testTheWidgetShowsZeroOnceTheCountedDayIsOver() {
        let day = at(2026, 10, 13)
        XCTAssertEqual(NVZapsToday.shown(count: 7, dayStart: day, at: at(2026, 10, 13, 23, 59), calendar: calendar), 7)
        // Drawn after midnight, before the next count: yesterday's 7 is not today's.
        XCTAssertEqual(NVZapsToday.shown(count: 7, dayStart: day, at: at(2026, 10, 14, 0, 1), calendar: calendar), 0)
        // A snapshot from before the count existed carries no day.
        XCTAssertEqual(NVZapsToday.shown(count: 7, dayStart: nil, at: day, calendar: calendar), 0)
    }

    func testAReceiptIsReadFromTheEvent() {
        let event: [String: Any] = ["id": "r1", "pubkey": "pub", "kind": 9735, "created_at": 1_760_000_000,
                                    "tags": [["p", me], ["e", "x"], ["bolt11", "lnbc"]]]
        XCTAssertEqual(NVZapsToday.Receipt(event: event),
                       NVZapsToday.Receipt(id: "r1", publisher: "pub", recipients: [me], createdAt: 1_760_000_000))
        let reaction: [String: Any] = ["id": "r2", "pubkey": "pub", "kind": 7, "created_at": 1, "tags": [[String]]()]
        XCTAssertNil(NVZapsToday.Receipt(event: reaction))
    }
}
