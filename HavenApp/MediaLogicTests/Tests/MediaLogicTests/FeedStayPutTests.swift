import XCTest
@testable import MediaLogic

/// The Feed never moves the reader on its own (Logen 2026-11-04).
final class FeedStayPutTests: XCTestCase {
    func testLoadEndJumpsOnlyAtTop() {
        XCTAssertTrue(FeedStayPut.scrollsToTopAfterLoad(isAtTop: true))
        XCTAssertFalse(FeedStayPut.scrollsToTopAfterLoad(isAtTop: false), "3-4 posts down: stay there")
    }

    func testAutoLoadNoLongerWaitsForTheTop() {
        XCTAssertTrue(FeedStayPut.autoLoads(enabled: true, waiting: 3, isLoading: false, postOpen: false))
        XCTAssertFalse(FeedStayPut.autoLoads(enabled: false, waiting: 3, isLoading: false, postOpen: false))
        XCTAssertFalse(FeedStayPut.autoLoads(enabled: true, waiting: 0, isLoading: false, postOpen: false))
        XCTAssertFalse(FeedStayPut.autoLoads(enabled: true, waiting: 3, isLoading: true, postOpen: false))
        XCTAssertFalse(FeedStayPut.autoLoads(enabled: true, waiting: 3, isLoading: false, postOpen: true))
    }

    func testBelowTheTopKeepsThePostBeingRead() {
        XCTAssertTrue(FeedStayPut.keepsReading(isAtTop: false))
        XCTAssertFalse(FeedStayPut.keepsReading(isAtTop: true))
    }
}
