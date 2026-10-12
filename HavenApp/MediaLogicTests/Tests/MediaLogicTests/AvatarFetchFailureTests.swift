import XCTest
@testable import MediaLogic

final class AvatarFetchFailureTests: XCTestCase {
    func testGoneStatusesMarkTheLinkDead() {
        XCTAssertEqual(AvatarFetchFailure(statusCode: 404, error: nil), .dead)
        XCTAssertEqual(AvatarFetchFailure(statusCode: 410, error: nil), .dead)
    }

    func testServerErrorsBackOffButAreNotDead() {
        for status in [500, 502, 503, 504] {
            XCTAssertEqual(AvatarFetchFailure(statusCode: status, error: nil), .backOff, "\(status)")
        }
    }

    /// Other answers (403 hotlink blocks, a 200 that isn't a picture) also
    /// back off rather than being asked again on every open.
    func testOtherAnswersBackOff() {
        XCTAssertEqual(AvatarFetchFailure(statusCode: 403, error: nil), .backOff)
        XCTAssertEqual(AvatarFetchFailure(statusCode: 200, error: nil), .backOff)
    }

    func testTimeoutsAndUnreachableHostsBackOff() {
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .timedOut), .backOff)
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .cannotFindHost), .backOff)
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .secureConnectionFailed), .backOff)
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: nil), .backOff)
    }

    /// Being offline says nothing about the link, so it must not hide
    /// every avatar for ten minutes after the phone reconnects.
    func testOfflineDoesNotBackOff() {
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .notConnectedToInternet), .retry)
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .networkConnectionLost), .retry)
        XCTAssertEqual(AvatarFetchFailure(statusCode: nil, error: .dataNotAllowed), .retry)
    }

    func testBackoffLastsTenMinutes() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let backoff = AvatarRetryBackoff(now: { now })
        let url = URL(string: "https://example.com/a.jpg")!
        XCTAssertFalse(backoff.isBackingOff(url))
        backoff.backOff(url)
        XCTAssertTrue(backoff.isBackingOff(url))
        now = now.addingTimeInterval(AvatarRetryBackoff.interval - 1)
        XCTAssertTrue(backoff.isBackingOff(url))
        now = now.addingTimeInterval(2)
        XCTAssertFalse(backoff.isBackingOff(url))
    }

    /// A new kind 0 with a different picture is a different key.
    func testBackoffIsPerURL() {
        let backoff = AvatarRetryBackoff()
        let old = URL(string: "https://example.com/old.jpg")!
        let new = URL(string: "https://example.com/new.jpg")!
        backoff.backOff(old)
        XCTAssertTrue(backoff.isBackingOff(old))
        XCTAssertFalse(backoff.isBackingOff(new))
    }

    func testClearEndsBackoff() {
        let backoff = AvatarRetryBackoff()
        let url = URL(string: "https://example.com/a.jpg")!
        backoff.backOff(url)
        backoff.clear(url)
        XCTAssertFalse(backoff.isBackingOff(url))
    }
}
