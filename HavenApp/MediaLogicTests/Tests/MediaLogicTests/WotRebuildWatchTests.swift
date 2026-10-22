import XCTest
@testable import MediaLogic

/// After an unfollow the app must pick up the relay's rebuilt web as soon as
/// the file changes, not at the next mode switch.
final class WotRebuildWatchTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_000_000)

    func testReloadsOnceTheRelayRewritesTheCache() {
        let before = start.addingTimeInterval(-3600)
        let watch = WotRebuildWatch(startedAt: start, stampAtStart: before)
        XCTAssertEqual(watch.step(stamp: before, now: start.addingTimeInterval(60)), .wait)
        XCTAssertEqual(watch.step(stamp: start.addingTimeInterval(300), now: start.addingTimeInterval(320)), .reload)
    }

    func testAFirstCacheCountsAsARewrite() {
        let watch = WotRebuildWatch(startedAt: start, stampAtStart: nil)
        XCTAssertEqual(watch.step(stamp: nil, now: start.addingTimeInterval(60)), .wait)
        XCTAssertEqual(watch.step(stamp: start.addingTimeInterval(90), now: start.addingTimeInterval(100)), .reload)
    }

    func testGivesUpAfterTheWindow() {
        let watch = WotRebuildWatch(startedAt: start, stampAtStart: start)
        XCTAssertEqual(watch.step(stamp: start, now: start.addingTimeInterval(WotRebuildWatch.window - 1)), .wait)
        XCTAssertEqual(watch.step(stamp: start, now: start.addingTimeInterval(WotRebuildWatch.window)), .stop)
    }
}
