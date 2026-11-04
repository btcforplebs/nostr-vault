import XCTest
@testable import MediaLogic

/// The Relays page says why a relay didn't connect (NDK check item 4, Logen 2026-11-04).
final class RelayFailReasonTests: XCTestCase {
    func testHTTPAnswersToTheUpgrade() {
        XCTAssertEqual(RelayFailReason.text(httpStatus: 403, urlErrorCode: NSURLErrorBadServerResponse), "refused (HTTP 403)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 401, urlErrorCode: nil), "refused (HTTP 401)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 404, urlErrorCode: nil), "no relay at this address (HTTP 404)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 429, urlErrorCode: nil), "rate-limited (HTTP 429)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 502, urlErrorCode: nil), "server error (HTTP 502)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 200, urlErrorCode: nil), "not a relay (answered with a web page)")
        XCTAssertEqual(RelayFailReason.text(httpStatus: 418, urlErrorCode: nil), "HTTP 418")
    }

    /// 101 is the upgrade itself: the reason is the error that came after.
    func testUpgradedThenFailedReadsTheError() {
        XCTAssertEqual(RelayFailReason.text(httpStatus: 101, urlErrorCode: NSURLErrorNetworkConnectionLost), "connection dropped")
    }

    func testNetworkErrors() {
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorCannotFindHost), "no such host")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorDNSLookupFailed), "no such host")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorCannotConnectToHost), "connection refused")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorNotConnectedToInternet), "you're offline")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorServerCertificateUntrusted), "certificate problem")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: NSURLErrorTimedOut), "timed out")
        XCTAssertEqual(RelayFailReason.text(httpStatus: nil, urlErrorCode: nil), "not answering")
        XCTAssertEqual(RelayFailReason.noAnswer(after: 6), "no answer in 6 s")
    }

    func testFromAnErrorAndResponse() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        XCTAssertEqual(RelayFailReason.text(response: nil, error: err), "no such host")
        let resp = HTTPURLResponse(url: URL(string: "https://relay.example")!, statusCode: 503, httpVersion: nil, headerFields: nil)
        XCTAssertEqual(RelayFailReason.text(response: resp, error: err), "server error (HTTP 503)")
        XCTAssertEqual(RelayFailReason.text(response: nil, error: NSError(domain: "other", code: -1003)), "not answering")
    }
}
