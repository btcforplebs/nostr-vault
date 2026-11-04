import XCTest
@testable import MediaLogic

/// Your space's On this day panel (OnThisDay). The web's on-this-day.test.mjs
/// covers the same rules.
final class OnThisDayTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Int64 {
        Int64(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970)
    }
    private func note(_ id: String, _ t: Int64, pubkey: String? = nil, kind: Int = 1, tags: [[String]] = []) -> OnThisDay.Note {
        OnThisDay.Note(id: id, pubkey: pubkey ?? me, kind: kind, createdAt: t, content: "\(id) text", tags: tags)
    }
    private var now: Date { Date(timeIntervalSince1970: TimeInterval(at(2026, 11, 4, 15))) }

    func testWindowIsTheWholeLocalDayYearsBack() {
        let w = OnThisDay.window(now: now, years: 1, calendar: cal)
        XCTAssertEqual(w, OnThisDay.Window(years: 1, since: at(2025, 11, 4, 0), until: at(2025, 11, 5, 0)))
        XCTAssertEqual(OnThisDay.windows(now: now, calendar: cal).map(\.years), [1, 2])
        XCTAssertEqual(OnThisDay.windows(now: now, calendar: cal)[1].since, at(2024, 11, 4, 0))
    }

    func testLeapDayHasNoDayInOtherYears() {
        let leap = Date(timeIntervalSince1970: TimeInterval(at(2028, 2, 29, 9)))
        XCTAssertNil(OnThisDay.window(now: leap, years: 1, calendar: cal))
        XCTAssertEqual(OnThisDay.window(now: leap, years: 4, calendar: cal)?.since, at(2024, 2, 29, 0))
        XCTAssertTrue(OnThisDay.windows(now: leap, calendar: cal).isEmpty)
    }

    func testOnlyOwnTopLevelNotesOnTheDayOldestFirstCapped() {
        let w = OnThisDay.window(now: now, years: 1, calendar: cal)!
        let all = [
            note("late", at(2025, 11, 4, 22)),
            note("early", at(2025, 11, 4, 7)),
            note("early", at(2025, 11, 4, 7)),
            note("day-before", at(2025, 11, 3, 23)),
            note("next-day", w.until),
            note("theirs", at(2025, 11, 4, 9), pubkey: other),
            note("like", at(2025, 11, 4, 9), kind: 7),
            note("reply", at(2025, 11, 4, 9), tags: [["e", String(repeating: "c", count: 64), "", "reply"]]),
            note("quote", at(2025, 11, 4, 10), tags: [["e", String(repeating: "c", count: 64), "", "mention"]]),
        ]
        XCTAssertEqual(OnThisDay.notes(all, owner: me, in: w).map(\.id), ["early", "quote", "late"])
        let many = (0..<6).map { note("n\($0)", at(2025, 11, 4, 8 + $0)) }
        XCTAssertEqual(OnThisDay.notes(many, owner: me, in: w).count, OnThisDay.perYear)
    }

    func testFilterAsksOnlyForOwnNotesInsideTheDay() {
        let w = OnThisDay.window(now: now, years: 2, calendar: cal)!
        let f = OnThisDay.filter(owner: me, w)
        XCTAssertEqual(f["authors"] as? [String], [me])
        XCTAssertEqual(f["kinds"] as? [Int], [1])
        XCTAssertEqual(f["since"] as? Int64, w.since)
        XCTAssertEqual(f["until"] as? Int64, w.until - 1)
    }

    func testWords() {
        XCTAssertEqual(OnThisDay.yearsText(1), "1 year ago")
        XCTAssertEqual(OnThisDay.yearsText(2), "2 years ago")
        XCTAssertEqual(OnThisDay.lineText("https://x.example/a.jpg"), "Photo")
        XCTAssertEqual(OnThisDay.lineText("https://x.example/a.jpg https://x.example/b.png?x=1"), "Photos")
        XCTAssertEqual(OnThisDay.lineText("gm  https://x.example/a.jpg\nworld"), "gm world")
    }
}
