import XCTest
@testable import MediaLogic

/// A waiting post re-uploads its whole file on every try, so tries back off
/// and stop instead of running every minute forever.
final class MediaPostRetryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(attempts: Int, lastAttempt: Date?, refused: Int? = nil) -> QueuedMediaPost {
        var p = QueuedMediaPost(accountNpub: "npub1me", body: "gm", media: [.init(sha256: String(repeating: "a", count: 64), mimeType: "image/jpeg", url: nil)], quoteSuffix: nil, baseTags: [])
        p.createdAt = start
        p.attempts = attempts
        p.lastAttempt = lastAttempt
        p.refusedStatus = refused
        return p
    }

    func testTheWaitDoublesFromOneMinuteAndStopsGrowingAtSixHours() {
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 1), 60)
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 2), 120)
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 5), 960)
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 9), 256 * 60)
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 10), 6 * 3600)
        XCTAssertEqual(MediaPostRetry.delay(afterAttempts: 500), 6 * 3600)
    }

    func testANewPostIsDueAtOnce() {
        XCTAssertTrue(post(attempts: 0, lastAttempt: nil).isDue(at: start))
    }

    func testAFailedPostWaitsOutItsBackoffEvenOnForegroundOrNetworkChange() {
        let tried = start.addingTimeInterval(1000)
        let p = post(attempts: 3, lastAttempt: tried)
        XCTAssertFalse(p.isDue(at: tried.addingTimeInterval(60)))
        XCTAssertFalse(p.isDue(at: tried.addingTimeInterval(239)))
        XCTAssertTrue(p.isDue(at: tried.addingTimeInterval(240)))
    }

    func testTenTriesInAFullDayInsteadOf1440() {
        var p = post(attempts: 0, lastAttempt: nil)
        var now = start
        var tries = 0
        while now < start.addingTimeInterval(24 * 3600) {
            if p.isDue(at: now) { p.attempts += 1; p.lastAttempt = now; tries += 1 }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(tries, MediaPostRetry.maxAutomaticAttempts)
        XCTAssertTrue(p.needsUser)
        XCTAssertNil(p.nextAttempt)
    }

    func testAServerThatRefusesTheFileStopsThePostAtOnce() {
        let p = post(attempts: 1, lastAttempt: start, refused: 413)
        XCTAssertTrue(p.needsUser)
        XCTAssertFalse(p.isDue(at: start.addingTimeInterval(365 * 86400)))
    }

    func testTheUserCanAlwaysSendItAgain() {
        var p = post(attempts: 10, lastAttempt: start, refused: 401)
        p.resetForUserRetry()
        XCTAssertFalse(p.needsUser)
        XCTAssertTrue(p.isDue(at: start))
    }

    func testOnlyARefusalByEveryMirrorStopsThePost() {
        let mirrors = ["https://a", "https://b"]
        XCTAssertTrue(MediaPostRetry.allRefused(mirrors: mirrors, statuses: ["https://a": 413, "https://b": 402]))
        // One mirror never answered (offline Mac): keep trying.
        XCTAssertFalse(MediaPostRetry.allRefused(mirrors: mirrors, statuses: ["https://a": 413]))
        // Busy or failing servers are not refusals.
        XCTAssertFalse(MediaPostRetry.allRefused(mirrors: mirrors, statuses: ["https://a": 429, "https://b": 401]))
        XCTAssertFalse(MediaPostRetry.allRefused(mirrors: mirrors, statuses: ["https://a": 503, "https://b": 401]))
        XCTAssertFalse(MediaPostRetry.allRefused(mirrors: mirrors, statuses: ["https://a": 408, "https://b": 401]))
        XCTAssertFalse(MediaPostRetry.allRefused(mirrors: [], statuses: [:]))
    }

    func testPostsQueuedByOlderBuildsStillDecode() throws {
        let old = #"{"id":"x","createdAt":0,"accountNpub":"npub1me","body":"gm","media":[],"baseTags":[],"powDifficulty":0,"attempts":4}"#
        let p = try JSONDecoder().decode(QueuedMediaPost.self, from: Data(old.utf8))
        XCTAssertNil(p.refusedStatus)
        XCTAssertEqual(p.attempts, 4)
    }
}
