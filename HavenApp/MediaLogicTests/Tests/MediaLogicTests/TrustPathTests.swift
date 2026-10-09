import XCTest
@testable import MediaLogic

final class TrustPathTests: XCTestCase {
    private let me = "me"
    private let author = "author"

    private func list(_ signer: String, tags: [String]) -> [String: Any] {
        ["kind": 3, "pubkey": signer, "tags": tags.map { ["p", $0] }]
    }

    func testAuthorIsYou() {
        let path = TrustPath.resolve(author: me, me: me, follows: ["a"], trustGraph: ["a"], contactLists: [])
        XCTAssertEqual(path.reach, .you)
    }

    func testDirectFollowKeepsBridges() {
        let path = TrustPath.resolve(author: author, me: me, follows: [author, "a"], trustGraph: ["x"],
                                     contactLists: [list("a", tags: [author])])
        XCTAssertEqual(path.reach, .follow)
        XCTAssertEqual(path.bridges, ["a"])
    }

    func testBridgesSortedCappedAndMore() {
        let follows: Set<String> = ["f", "e", "d", "c", "b", "a"]
        let lists = follows.map { list($0, tags: [author]) }
        let path = TrustPath.resolve(author: author, me: me, follows: follows, trustGraph: ["x"], contactLists: lists)
        XCTAssertEqual(path.reach, .bridged)
        XCTAssertEqual(path.bridges, ["a", "b", "c", "d", "e"])
        XCTAssertTrue(path.hasMore)
    }

    func testIgnoresStrangersListsWithoutAuthorAndWrongKind() {
        var wrongKind = list("b", tags: [author]); wrongKind["kind"] = 1
        let lists = [list("stranger", tags: [author]), list("a", tags: ["other"]), wrongKind]
        let path = TrustPath.resolve(author: author, me: me, follows: ["a", "b"], trustGraph: [author],
                                     contactLists: lists)
        XCTAssertEqual(path.reach, .web)
        XCTAssertTrue(path.bridges.isEmpty)
        XCTAssertFalse(path.hasMore)
    }

    func testOnlyEachSignersNewestListCounts() {
        var old = list("a", tags: [author]); old["created_at"] = 100
        var new = list("a", tags: ["other"]); new["created_at"] = 200
        for lists in [[old, new], [new, old]] {
            let path = TrustPath.resolve(author: author, me: me, follows: ["a"], trustGraph: ["a"],
                                         contactLists: lists)
            XCTAssertEqual(path.reach, .outside)
        }
    }

    func testOutsideNeedsAGraph() {
        XCTAssertEqual(TrustPath.resolve(author: author, me: me, follows: ["a"], trustGraph: ["a"],
                                         contactLists: []).reach, .outside)
        XCTAssertEqual(TrustPath.resolve(author: author, me: me, follows: ["a"], trustGraph: [],
                                         contactLists: []).reach, .unknown)
    }

    func testFiltersChunkAndSkipAuthor() {
        let follows = (0..<501).map { "p\($0)" } + [author]
        let filters = TrustPath.filters(author: author, follows: follows, chunkSize: 250)
        XCTAssertEqual(filters.count, 3)
        XCTAssertEqual(filters.compactMap { ($0["authors"] as? [String])?.count }, [250, 250, 1])
        XCTAssertFalse(filters.contains { ($0["authors"] as? [String])?.contains(author) == true })
        XCTAssertEqual(filters[0]["#p"] as? [String], [author])
        XCTAssertEqual(filters[0]["limit"] as? Int, TrustPath.listsPerFilter)
        // A typical account (~1,000 follows) sends one filter.
        XCTAssertEqual(TrustPath.filters(author: author, follows: Array(follows.prefix(1000))).count, 1)
    }
}
