import XCTest
@testable import MediaLogic

/// "Check sync with Mac" ends on "Done" with what was copied, or on the reason
/// the copy stopped.
final class MacSyncSummaryTests: XCTestCase {
    private func status(_ state: String, posts: Int = 0, mentions: Int = 0, missing: Int = 0, error: String? = nil) -> RelayConfiguration.MacSyncStatus {
        var s = RelayConfiguration.MacSyncStatus()
        s.state = state
        s.posts = posts
        s.mentions = mentions
        s.missing = missing
        s.error = error
        return s
    }

    func testDoneShowsCounts() {
        let s = RelayConfiguration.macSyncSummary(status("done", posts: 120, mentions: 7), checked: "Oct 21, 12:12")
        XCTAssertEqual(s.headline, "Done · nothing missing")
        XCTAssertEqual(s.detail, "Copied 120 posts and 7 mentions. Checked Oct 21, 12:12.")
    }

    func testRecheckWithNothingNewSaysSo() {
        let s = RelayConfiguration.macSyncSummary(status("done"), checked: nil)
        XCTAssertEqual(s.detail, "Nothing new to copy: this phone already had it.")
    }

    /// Logen's 12 mini: a clean finish with 25 events the phone won't store.
    func testCleanIncompleteIsDoneWithLeftovers() {
        let s = RelayConfiguration.macSyncSummary(status("incomplete", posts: 476, mentions: 167, missing: 25), checked: nil)
        XCTAssertEqual(s.headline, "Done · 25 couldn't be copied")
        XCTAssertEqual(s.detail, "Copied 476 posts and 167 mentions. It tries those again once a day.")
    }

    func testIncompleteWithErrorGivesTheReason() {
        let s = RelayConfiguration.macSyncSummary(status("incomplete", posts: 3, missing: 9, error: "mentions: timeout"), checked: nil)
        XCTAssertEqual(s.headline, "Stopped · 9 still missing")
        XCTAssertTrue(s.detail.contains("Reason: mentions: timeout."), s.detail)
    }

    func testFailedGivesTheReason() {
        let s = RelayConfiguration.macSyncSummary(status("failed", error: "posts: connection refused"), checked: nil)
        XCTAssertEqual(s.headline, "Couldn't copy from your Mac")
        XCTAssertEqual(s.detail, "Reason: posts: connection refused. It tries again next time the app starts.")
        let unknown = RelayConfiguration.macSyncSummary(status("failed"), checked: nil)
        XCTAssertTrue(unknown.detail.hasPrefix("Reason: none was recorded."), unknown.detail)
    }

    func testStatusMatchesTheMacIgnoringTrailingSlash() {
        var s = RelayConfiguration.MacSyncStatus()
        s.macURL = "ws://127.0.0.1:63218/abc"
        XCTAssertTrue(RelayConfiguration.macSyncStatus(s, isFor: "ws://127.0.0.1:63218/abc/"))
        XCTAssertFalse(RelayConfiguration.macSyncStatus(s, isFor: "ws://127.0.0.1:62608/def"))
        XCTAssertFalse(RelayConfiguration.macSyncStatus(s, isFor: ""))
    }
}
