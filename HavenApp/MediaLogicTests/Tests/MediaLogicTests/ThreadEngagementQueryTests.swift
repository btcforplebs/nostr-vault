import XCTest
@testable import MediaLogic

final class ThreadEngagementQueryTests: XCTestCase {
    private func ids(_ count: Int) -> [String] {
        (0..<count).map { String(format: "%064x", $0) }
    }

    func testEveryNoteLandsInExactlyOneRequest() {
        let noteIds = ids(37)
        let requests = ThreadEngagementQuery.requests(for: noteIds, subscriptionPrefix: "eng")
        let batched = requests.flatMap(\.noteIds)
        XCTAssertEqual(batched.count, noteIds.count)
        XCTAssertEqual(Set(batched), Set(noteIds))
    }

    func testBatchesAreCappedSoNotesDoNotShareOneLimit() {
        let requests = ThreadEngagementQuery.requests(for: ids(37), subscriptionPrefix: "eng")
        XCTAssertEqual(requests.map(\.noteIds.count), [10, 10, 10, 7])
        for request in requests {
            XCTAssertEqual(request.filter["limit"] as? Int, ThreadEngagementQuery.limit)
            XCTAssertEqual(request.filter["#e"] as? [String], request.noteIds)
            XCTAssertEqual(request.filter["kinds"] as? [Int], [6, 7, 9735])
        }
    }

    func testSubscriptionIdsAreDistinct() {
        let requests = ThreadEngagementQuery.requests(for: ids(25), subscriptionPrefix: "eng")
        XCTAssertEqual(requests.map(\.subscriptionId), ["eng-0", "eng-1", "eng-2"])
    }

    func testSplitIsStableAndIgnoresDuplicates() {
        let noteIds = ids(15)
        let forward = ThreadEngagementQuery.requests(for: noteIds + noteIds.prefix(3), subscriptionPrefix: "eng")
        let reversed = ThreadEngagementQuery.requests(for: noteIds.reversed(), subscriptionPrefix: "eng")
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.flatMap(\.noteIds).count, 15)
    }

    func testEmptyThreadSendsNothing() {
        XCTAssertTrue(ThreadEngagementQuery.requests(for: [String](), subscriptionPrefix: "eng").isEmpty)
    }
}
