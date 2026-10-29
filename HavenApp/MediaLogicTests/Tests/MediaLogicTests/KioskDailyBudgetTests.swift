import XCTest
@testable import MediaLogic

/// Strangers get one daily budget from an iPhone kiosk, however many
/// sessions (cool-downs, leaving the app and coming back) it is split into.
final class KioskDailyBudgetTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let mb: UInt64 = 1 << 20
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12))! }
    private var midnight: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))! }

    private func fresh() -> KioskDailyBudget {
        KioskDailyBudget(day: KioskDailyBudget.dayKey(noon, calendar: calendar))
    }

    func testANewSessionGetsOnlyWhatIsLeftOfToday() {
        var budget = fresh()
        budget.engineStarted()
        budget.record(engineTx: 100 * mb, now: noon, calendar: calendar)
        budget.record(engineTx: 700 * mb, now: noon, calendar: calendar)
        XCTAssertEqual(budget.usedBytes, Int64(700 * mb))
        // The owner leaves the app and comes back: a new engine counts from 0.
        budget.engineStarted()
        XCTAssertEqual(budget.sessionLimit, Int64(324 * mb))
        budget.record(engineTx: 24 * mb, now: noon, calendar: calendar)
        XCTAssertEqual(budget.usedBytes, Int64(724 * mb))
    }

    func testAnEngineCountThatDropsIsANewSessionNotANegativeOne() {
        var budget = fresh()
        budget.record(engineTx: 500 * mb, now: noon, calendar: calendar)
        budget.record(engineTx: 10 * mb, now: noon, calendar: calendar)
        XCTAssertEqual(budget.usedBytes, Int64(510 * mb))
    }

    func testASpentDayStillSendsALimitTheEngineDoesNotReadAsItsDefault() {
        var budget = fresh()
        budget.record(engineTx: 2048 * mb, now: noon, calendar: calendar)
        XCTAssertTrue(budget.spent)
        XCTAssertEqual(budget.usedBytes, KioskDailyBudget.daily)
        XCTAssertEqual(budget.sessionLimit, 1)
    }

    func testTheLimitReachedTodayPausesStrangersUntilMidnight() {
        var budget = fresh()
        budget.record(engineTx: 1000 * mb, now: noon, calendar: calendar)
        // The poll lags the engine: the cap still spends the day.
        let at = budget.capReached(sessionDay: budget.day, now: noon, calendar: calendar)
        XCTAssertEqual(at, midnight)
        XCTAssertTrue(budget.spent)
    }

    func testASessionFromYesterdaySharesAgainAtOnceOnANewDay() {
        var budget = fresh()
        let yesterday = budget.day
        budget.record(engineTx: 900 * mb, now: noon, calendar: calendar)
        let later = midnight.addingTimeInterval(1800)
        let at = budget.capReached(sessionDay: yesterday, now: later, calendar: calendar)
        XCTAssertEqual(at, later)
        XCTAssertEqual(budget.usedBytes, 0)
        XCTAssertEqual(budget.sessionLimit, KioskDailyBudget.daily)
    }

    func testTheBudgetSurvivesAnAppRelaunch() throws {
        var budget = fresh()
        budget.record(engineTx: 300 * mb, now: noon, calendar: calendar)
        let reloaded = try JSONDecoder().decode(KioskDailyBudget.self, from: JSONEncoder().encode(budget))
        XCTAssertEqual(reloaded.usedBytes, Int64(300 * mb))
    }
}
