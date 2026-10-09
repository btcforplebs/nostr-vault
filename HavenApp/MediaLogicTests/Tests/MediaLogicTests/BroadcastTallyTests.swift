import XCTest
@testable import MediaLogic

final class BroadcastTallyTests: XCTestCase {
    func testFirstAcceptDecidesAccepted() {
        var t = BroadcastTally(relayCount: 3)
        XCTAssertNil(t.record(relay: "a", success: false, message: "blocked: no"))
        XCTAssertEqual(t.record(relay: "b", success: true, message: ""), .accepted)
        // Decided once; a later refusal can't flip it.
        XCTAssertNil(t.record(relay: "c", success: false, message: "timeout"))
        XCTAssertEqual(t.outcome, .accepted)
    }

    func testRefusedOnlyWhenEveryRelayAnswered() {
        var t = BroadcastTally(relayCount: 2)
        XCTAssertNil(t.record(relay: "a", success: false, message: "timeout"))
        XCTAssertNil(t.outcome)
        XCTAssertEqual(t.record(relay: "b", success: false, message: "connection failed"), .refused)
    }

    func testRepeatedAnswerFromOneRelayCountsOnce() {
        var t = BroadcastTally(relayCount: 2)
        XCTAssertNil(t.record(relay: "a", success: false, message: "timeout"))
        XCTAssertNil(t.record(relay: "a", success: false, message: "timeout"))
        XCTAssertNil(t.outcome)
    }

    func testDuplicateCountsAsAccepted() {
        var t = BroadcastTally(relayCount: 2)
        XCTAssertEqual(t.record(relay: "a", success: false, message: "duplicate: already have this event"), .accepted)
    }

    func testNoRelaysIsRefused() {
        XCTAssertEqual(BroadcastTally(relayCount: 0).outcome, .refused)
    }
}
