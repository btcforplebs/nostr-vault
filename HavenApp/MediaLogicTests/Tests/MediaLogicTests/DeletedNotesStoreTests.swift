import XCTest
@testable import MediaLogic

/// Deleted ids survive a restart and stay with their account.
final class DeletedNotesStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("deleted-notes-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMarkedIdsComeBackFromDisk() {
        DeletedNotesStore(directory: directory).markDeleted(["a1", "b2"], account: "acct")
        let reopened = DeletedNotesStore(directory: directory)
        XCTAssertEqual(reopened.ids(forAccount: "acct"), ["a1", "b2"])
        XCTAssertTrue(reopened.contains("a1", account: "acct"))
    }

    func testAccountsAreKeptApart() {
        let store = DeletedNotesStore(directory: directory)
        store.markDeleted(["a1"], account: "one")
        XCTAssertFalse(store.contains("a1", account: "two"))
        XCTAssertEqual(store.ids(forAccount: "two"), [])
    }

    func testMarkingAgainAddsToWhatIsThere() {
        let store = DeletedNotesStore(directory: directory)
        store.markDeleted(["a1"], account: "acct")
        store.markDeleted(["a1", "c3"], account: "acct")
        XCTAssertEqual(DeletedNotesStore(directory: directory).ids(forAccount: "acct"), ["a1", "c3"])
    }

    func testNothingToMarkWritesNothing() {
        let store = DeletedNotesStore(directory: directory)
        store.markDeleted([], account: "acct")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(forAccount: "acct").path))
    }

    // A replayed kind 5 costs a lookup, not a signature check and a purge.

    func testARequestIsClaimedOnce() {
        let store = DeletedNotesStore(directory: directory)
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "acct"), ["a1"])
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "acct"), [])
    }

    func testPostsAlreadyOffTheFeedAreNotReturned() {
        let store = DeletedNotesStore(directory: directory)
        store.markAppliedToFeed(["a1"], account: "acct")
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "acct"), [])
        XCTAssertEqual(store.claimRequest("r2", naming: ["a1", "b2"], account: "acct"), ["b2"])
    }

    func testAppliedPostsStayWithTheirAccount() {
        let store = DeletedNotesStore(directory: directory)
        store.markAppliedToFeed(["a1"], account: "one")
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "two"), ["a1"])
    }

    func testAReleasedRequestCanBeClaimedAgain() {
        let store = DeletedNotesStore(directory: directory)
        _ = store.claimRequest("r1", naming: ["a1"], account: "acct")
        store.releaseRequest("r1")
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "acct"), ["a1"])
    }

    /// Marking deleted on disk (a delete made on this device) does not take
    /// the post off the feed, so the relay's echo of that request still does.
    func testMarkedDeletedIsNotAppliedToFeed() {
        let store = DeletedNotesStore(directory: directory)
        store.markDeleted(["a1"], account: "acct")
        XCTAssertEqual(store.claimRequest("r1", naming: ["a1"], account: "acct"), ["a1"])
    }

    func testAppliedIdsAreNotWrittenToDisk() {
        DeletedNotesStore(directory: directory).markAppliedToFeed(["a1"], account: "acct")
        XCTAssertEqual(DeletedNotesStore(directory: directory).claimRequest("r1", naming: ["a1"], account: "acct"), ["a1"])
    }
}
