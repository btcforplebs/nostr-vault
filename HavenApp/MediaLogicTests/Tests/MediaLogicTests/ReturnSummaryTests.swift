import XCTest
@testable import MediaLogic

final class ReturnSummaryTests: XCTestCase {

    // MARK: - The pill's text

    func testCountsByKindInLogensOrder() {
        var s = ReturnSummary()
        s.add(type: "dm", key: "d1")
        for i in 0..<5 { s.add(type: "mention", key: "m\(i)") }
        s.add(type: "zap", key: "z1")
        s.add(type: "zap", key: "z2")
        XCTAssertEqual(s.text, "5 mentions · 2 zaps · 1 DM")
        XCTAssertEqual(s.total, 8)
    }

    /// The relay marker and the system alert for one event both reach the
    /// pill path; the event counts once.
    func testOneEventCountsOnce() {
        var s = ReturnSummary()
        XCTAssertTrue(s.add(type: "mention", key: "abc"))
        XCTAssertFalse(s.add(type: "mention", key: "abc"))
        XCTAssertEqual(s.text, "1 mention")
    }

    func testQuoteIsAMentionAndGiftWrapIsADM() {
        var s = ReturnSummary()
        s.add(type: "quote", key: "q")
        s.add(type: "mention", key: "m")
        s.add(type: "giftwrap", key: "g")
        XCTAssertEqual(s.count(.mention), 2)
        XCTAssertEqual(s.count(.dm), 1)
    }

    func testPastThreeKindsTheRestFoldIntoMore() {
        var s = ReturnSummary()
        s.add(type: "mention", key: "1")
        s.add(type: "reply", key: "2")
        s.add(type: "zap", key: "3")
        s.add(type: "reaction", key: "4")
        s.add(type: "reaction", key: "5")
        s.add(type: "follow", key: "6")
        XCTAssertEqual(s.text, "1 mention · 1 reply · 1 zap · +3 more")
        XCTAssertEqual(s.spokenText, "1 mention, 1 reply, 1 zap, 2 reactions, 1 new follower")
    }

    func testUnknownTypeIsAnUpdate() {
        var s = ReturnSummary()
        s.add(type: "something-new", key: "x")
        XCTAssertEqual(s.text, "1 update")
    }

    func testEmpty() {
        XCTAssertTrue(ReturnSummary().isEmpty)
        XCTAssertEqual(ReturnSummary().text, "")
    }

    // MARK: - The gathering window

    private let back = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { back.addingTimeInterval(s) }

    func testNothingArrivesThenItClosesAndLiveTrafficGetsTopPills() {
        var w = ReturnWindow(returnedAt: back)
        XCTAssertTrue(w.gathers(at: at(ReturnWindow.waitForFirst - 0.1)))
        XCTAssertNil(w.showsUntil, "no arrival, no pill")
        XCTAssertFalse(w.arrive(at: at(ReturnWindow.waitForFirst)))
        XCTAssertNil(w.showsUntil)
    }

    func testEachArrivalKeepsItOpenASettleLonger() {
        var w = ReturnWindow(returnedAt: back)
        XCTAssertTrue(w.arrive(at: at(2)))
        XCTAssertTrue(w.arrive(at: at(7)))
        XCTAssertEqual(w.gathersUntil, at(7 + ReturnWindow.settle))
        XCTAssertTrue(w.gathers(at: at(12.9)))
        XCTAssertFalse(w.gathers(at: at(13)))
    }

    /// A busy account keeps arriving; past `maximum` it is live traffic again.
    func testNeverGathersPastTheMaximum() {
        var w = ReturnWindow(returnedAt: back)
        var t: TimeInterval = 1
        while w.arrive(at: at(t)) { t += 2 }
        XCTAssertLessThanOrEqual(t, ReturnWindow.maximum + 2)
        XCTAssertEqual(w.gathersUntil, at(ReturnWindow.maximum))
    }

    /// One arrival just before the close still gets a readable pill.
    func testALateFirstArrivalStillShowsTheMinimum() {
        var w = ReturnWindow(returnedAt: back)
        XCTAssertTrue(w.arrive(at: at(11)))
        XCTAssertEqual(w.showsUntil, at(11 + ReturnWindow.settle))
        var capped = ReturnWindow(returnedAt: back)
        var t: TimeInterval = 1
        while t < ReturnWindow.maximum - 1 { _ = capped.arrive(at: at(t)); t += 4 }
        XCTAssertEqual(capped.showsUntil, at(ReturnWindow.maximum))
        var single = ReturnWindow(returnedAt: back)
        _ = single.arrive(at: at(ReturnWindow.maximum - 25))
        XCTAssertGreaterThanOrEqual(single.showsUntil!, at(ReturnWindow.maximum - 25 + ReturnWindow.minimumShow))
    }
}
