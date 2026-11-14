import XCTest
@testable import MediaLogic

/// A `.fips` site that does not answer yet is asked again, not given up on
/// at the first reset (Logen 2026-11-14).
final class MeshSiteRetryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheRequestTimeoutOutlastsTheLookupAndTheDoorsConnect() {
        // Fork lookup ladder 1+2+4+8 s, door SYN timeout 20 s (fips-v2 stack.rs).
        XCTAssertGreaterThan(MeshSiteRetry.requestTimeout, 35)
        XCTAssertGreaterThanOrEqual(MeshSiteRetry.window, MeshSiteRetry.requestTimeout)
    }

    func testAResetEarlyIsAskedAgain() {
        XCTAssertTrue(MeshSiteRetry.shouldRetry(startedAt: start, now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(MeshSiteRetry.shouldRetry(startedAt: start, now: start.addingTimeInterval(20)), "the door's first SYN timeout")
    }

    func testThePageGivesUpAtTheWindow() {
        let last = MeshSiteRetry.window - MeshSiteRetry.pause
        XCTAssertFalse(MeshSiteRetry.shouldRetry(startedAt: start, now: start.addingTimeInterval(last)))
        XCTAssertFalse(MeshSiteRetry.shouldRetry(startedAt: start, now: start.addingTimeInterval(MeshSiteRetry.window + 1)))
    }
}
