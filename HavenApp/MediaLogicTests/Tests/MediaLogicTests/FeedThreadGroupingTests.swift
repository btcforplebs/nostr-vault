import XCTest
@testable import MediaLogic

/// Stands in for `FeedNote` so the thread tree can be tested without a relay,
/// a service, or a view.
private struct TestNote: ThreadGroupable {
    let id: String
    let authorPubkey: String
    let createdAt: Date
    let parentEventId: String?
    let tags: [[String]]

    init(_ id: String, at seconds: TimeInterval, parent: String? = nil, root: String? = nil, author: String = "alice") {
        self.id = id
        self.authorPubkey = author
        self.createdAt = Date(timeIntervalSince1970: seconds)
        self.parentEventId = parent
        var tags: [[String]] = []
        if let root { tags.append(["e", root, "", "root"]) }
        if let parent, parent != root { tags.append(["e", parent, "", "reply"]) }
        self.tags = tags
    }
}

final class FeedThreadGroupingTests: XCTestCase {

    private func ids(_ thread: FeedThread<TestNote>) -> [String] {
        thread.entries.map(\.id)
    }

    private func depths(_ thread: FeedThread<TestNote>) -> [Int] {
        thread.entries.map(\.depth)
    }

    func testStandaloneNotesEachBecomeTheirOwnThread() {
        let notes = [TestNote("b", at: 200), TestNote("a", at: 100)]
        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertEqual(threads.map(\.rootId), ["b", "a"])
        XCTAssertEqual(threads.map { $0.entries.count }, [1, 1])
        XCTAssertTrue(threads.allSatisfy { $0.replies.isEmpty })
    }

    func testRepliesCollapseIntoTheRootThreadInReadingOrder() {
        // root -> r1 -> r2, plus a second top-level reply r3.
        let notes = [
            TestNote("r3", at: 400, parent: "root", root: "root", author: "carol"),
            TestNote("r2", at: 300, parent: "r1", root: "root", author: "bob"),
            TestNote("r1", at: 200, parent: "root", root: "root", author: "bob"),
            TestNote("root", at: 100),
        ]

        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertEqual(threads.count, 1)
        let thread = threads[0]
        XCTAssertEqual(thread.rootId, "root")
        XCTAssertEqual(thread.root?.id, "root")
        XCTAssertEqual(ids(thread), ["root", "r1", "r2", "r3"])
        XCTAssertEqual(depths(thread), [0, 1, 2, 1])
        XCTAssertEqual(thread.replies.map(\.id), ["r1", "r2", "r3"])
    }

    func testThreadsSortByLatestActivityNotRootAge() {
        // An old root with a fresh reply must outrank a newer standalone note.
        let notes = [
            TestNote("fresh", at: 500),
            TestNote("reply", at: 900, parent: "old", root: "old", author: "bob"),
            TestNote("old", at: 100),
        ]

        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertEqual(threads.map(\.rootId), ["old", "fresh"])
        XCTAssertEqual(threads[0].latestActivity, Date(timeIntervalSince1970: 900))
    }

    func testMissingRootIsResolvedThroughTheCallback() {
        let missingRoot = TestNote("root", at: 100)
        let notes = [TestNote("r1", at: 200, parent: "root", root: "root", author: "bob")]

        let threads = FeedThreadGrouping.build(notes: notes) { id in
            id == "root" ? missingRoot : nil
        }

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].root?.id, "root")
        XCTAssertEqual(ids(threads[0]), ["root", "r1"])
        XCTAssertEqual(depths(threads[0]), [0, 1])
    }

    func testUnresolvableRootStillGroupsItsRepliesTogether() {
        // Two sibling replies whose shared root never loaded belong to one card,
        // not two — that is what the NIP-10 root tag is for.
        let notes = [
            TestNote("r2", at: 300, parent: "r1", root: "ghost", author: "bob"),
            TestNote("r1", at: 200, parent: "ghost", root: "ghost", author: "bob"),
        ]

        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].rootId, "ghost")
        XCTAssertNil(threads[0].root)
        XCTAssertEqual(ids(threads[0]), ["r1", "r2"])
        // Without a root to sit at depth 0, its replies start the indentation.
        XCTAssertEqual(depths(threads[0]), [1, 2])
        XCTAssertEqual(threads[0].replies.map(\.id), ["r1", "r2"])
    }

    func testIndentationStopsAtMaxDepth() {
        var notes = [TestNote("n0", at: 0)]
        for i in 1...(FeedThreadGrouping.maxDepth + 3) {
            notes.append(TestNote("n\(i)", at: TimeInterval(i), parent: "n\(i - 1)", root: "n0"))
        }

        let threads = FeedThreadGrouping.build(notes: notes.reversed())

        XCTAssertEqual(threads.count, 1)
        let observed = depths(threads[0])
        XCTAssertEqual(observed.first, 0)
        XCTAssertEqual(observed.max(), FeedThreadGrouping.maxDepth)
        // Every note is still present — capping indents, it never drops replies.
        XCTAssertEqual(observed.count, notes.count)
    }

    func testParticipantsAreRootFirstAndDeduplicated() {
        let notes = [
            TestNote("r2", at: 300, parent: "root", root: "root", author: "alice"),
            TestNote("r1", at: 200, parent: "root", root: "root", author: "bob"),
            TestNote("root", at: 100, author: "alice"),
        ]

        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertEqual(threads[0].participantPubkeys, ["alice", "bob"])
    }

    func testCycleDoesNotHang() {
        // A malformed pair that each claim the other as parent must terminate.
        let notes = [
            TestNote("a", at: 100, parent: "b"),
            TestNote("b", at: 200, parent: "a"),
        ]

        let threads = FeedThreadGrouping.build(notes: notes)

        XCTAssertFalse(threads.isEmpty)
        let total = threads.reduce(0) { $0 + $1.entries.count }
        XCTAssertEqual(total, 2)
    }

    func testEmptyFeedProducesNoThreads() {
        XCTAssertTrue(FeedThreadGrouping.build(notes: [TestNote]()).isEmpty)
    }
}
