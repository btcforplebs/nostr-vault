import XCTest
@testable import MediaLogic

/// Forgetting a relay's live REQ forgets its distant list too. The two lists
/// used to live in separate maps, and only the author map was ever cleared.
final class FeedSubscriptionLedgerTests: XCTestCase {
    private let key = "ws://127.0.0.1:4869/feed"
    private let far = ["f1", "f2"]

    func testForgetDropsTheDistantListWithTheAuthors() {
        var ledger = FeedSubscriptionLedger()
        ledger.record(key, authors: ["a"], distant: far)
        ledger.forget(key)
        XCTAssertNil(ledger[key])
        XCTAssertFalse(ledger.isInSync(key, authors: ["a"], distant: far))
    }

    func testForgetAllDropsEveryDistantList() {
        var ledger = FeedSubscriptionLedger()
        ledger.record(key, authors: ["a"], distant: far)
        ledger.record("wss://other", authors: ["b"], distant: [])
        ledger.forgetAll()
        XCTAssertNil(ledger[key])
        XCTAssertNil(ledger["wss://other"])
    }

    func testInSyncIgnoresAuthorOrderButNotDistantOrder() {
        var ledger = FeedSubscriptionLedger()
        ledger.record(key, authors: ["a", "b"], distant: far)
        XCTAssertTrue(ledger.isInSync(key, authors: ["b", "a"], distant: far))
        XCTAssertFalse(ledger.isInSync(key, authors: ["a", "b"], distant: far.reversed()))
        XCTAssertFalse(ledger.isInSync(key, authors: ["a"], distant: far))
        XCTAssertFalse(ledger.isInSync(key, authors: ["a", "b"], distant: []))
    }

    func testANewRecordReplacesBothLists() {
        var ledger = FeedSubscriptionLedger()
        ledger.record(key, authors: ["a"], distant: far)
        ledger.record(key, authors: ["a"], distant: [])
        XCTAssertEqual(ledger[key], .init(authors: ["a"], distant: []))
    }

    func testNothingRecordedIsNeverInSync() {
        XCTAssertFalse(FeedSubscriptionLedger().isInSync(key, authors: [], distant: []))
    }
}
