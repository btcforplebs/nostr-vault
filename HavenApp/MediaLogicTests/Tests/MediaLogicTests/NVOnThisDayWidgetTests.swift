import XCTest
@testable import MediaLogic

/// The On this day home screen widget: what the snapshot shows on which day,
/// and the `nostrvault://note/<id>` link a tap opens.
final class NVOnThisDayWidgetTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    private let id1 = String(repeating: "a", count: 64)
    private let id2 = String(repeating: "b", count: 64)
    private let id3 = String(repeating: "c", count: 64)

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func snapshot() -> NVOnThisDaySnapshot {
        NVOnThisDaySnapshot(dayStart: cal.startOfDay(for: date(2026, 11, 4)), years: [
            .init(years: 1, notes: [.init(id: id1, text: "one", createdAt: date(2025, 11, 4, 8)),
                                    .init(id: id2, text: "two", createdAt: date(2025, 11, 4, 19))]),
            .init(years: 2, notes: [.init(id: id3, text: "three", createdAt: date(2024, 11, 4, 14))]),
        ])
    }

    func testShowsTheNotesOnTheDayTheyWereReadFor() {
        let rows = snapshot().rows(at: date(2026, 11, 4, 23), calendar: cal)
        XCTAssertEqual(rows.map(\.note.id), [id1, id2, id3])
        XCTAssertEqual(rows.map(\.years), [1, 1, 2])
    }

    func testShowsNothingOnceThatDayIsOver() {
        XCTAssertTrue(snapshot().rows(at: date(2026, 11, 5, 0), calendar: cal).isEmpty)
        XCTAssertTrue(snapshot().rows(at: date(2026, 11, 3, 23), calendar: cal).isEmpty)
    }

    func testAYearWithNoNotesIsLeftOut() {
        var s = snapshot()
        s.years[0].notes = []
        XCTAssertEqual(s.shown(at: date(2026, 11, 4), calendar: cal).map(\.years), [2])
    }

    func testAnOlderSnapshotWithoutOnThisDayStillDecodes() throws {
        let old = try JSONEncoder().encode(NVWidgetSnapshot.empty)
        var json = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        json.removeValue(forKey: "onThisDay")
        let decoded = try JSONDecoder().decode(NVWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.onThisDay)
    }

    func testTheSnapshotRoundTrips() throws {
        var s = NVWidgetSnapshot.empty
        s.onThisDay = snapshot()
        let back = try JSONDecoder().decode(NVWidgetSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.onThisDay, snapshot())
    }

    func testANoteLinkCarriesTheIdAndParsesBack() {
        let url = NVDeepLink.noteURL(id1.uppercased())!
        XCTAssertEqual(url.absoluteString, "nostrvault://note/\(id1)")
        XCTAssertEqual(NVDeepLink.noteID(from: url), id1)
        XCTAssertEqual(NVDeepLink.noteID(from: URL(string: "nostrvault:///note/\(id1)")!), id1)
    }

    func testOnlyAWholeHexIdIsANoteLink() {
        XCTAssertNil(NVDeepLink.noteURL("abc"))
        XCTAssertNil(NVDeepLink.noteURL(String(repeating: "z", count: 64)))
        XCTAssertNil(NVDeepLink.noteID(from: URL(string: "nostrvault://note/abc")!))
        XCTAssertNil(NVDeepLink.noteID(from: URL(string: "nostrvault://feed")!))
        XCTAssertNil(NVDeepLink.noteID(from: URL(string: "nostr:note/\(id1)")!))
        XCTAssertNil(NVDeepLink.noteID(from: URL(string: "nostrvault://note/\(id1)/extra")!))
        // The plain links still parse as before.
        XCTAssertEqual(NVDeepLink(url: URL(string: "nostrvault://feed")!), .feed)
        XCTAssertNil(NVDeepLink(url: URL(string: "nostrvault://note/\(id1)")!))
    }
}
