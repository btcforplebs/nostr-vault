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

    func testAllKeepsEveryBridgePastTheCard() {
        let follows: Set<String> = ["f", "e", "d", "c", "b", "a"]
        let path = TrustPath.resolve(author: author, follows: follows, trustGraph: ["x"],
                                     bridges: ["a", "b", "c", "d", "e", "f"])
        XCTAssertEqual(path.bridges, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(path.all, ["a", "b", "c", "d", "e", "f"])
        XCTAssertTrue(path.hasMore)
    }

    /// From the saved web the globe lights everyone at once; from a relay's
    /// few lists only the card's five, until "Show everyone".
    func testTheGlobeLightsEveryoneOnlyWhenTheSavedWebKnewThem() {
        let follows: Set<String> = ["f", "e", "d", "c", "b", "a"]
        let saved = TrustPath.resolve(author: author, follows: follows, trustGraph: ["x"],
                                      bridges: ["a", "b", "c", "d", "e", "f"], complete: true)
        XCTAssertEqual(saved.lit, ["a", "b", "c", "d", "e", "f"])
        let lists = follows.map { list($0, tags: [author]) }
        let fetched = TrustPath.resolve(author: author, me: me, follows: follows, trustGraph: ["x"], contactLists: lists)
        XCTAssertFalse(fetched.complete)
        XCTAssertEqual(fetched.lit, ["a", "b", "c", "d", "e"])
    }

    /// The relay's links file: indexes into its follows, as of the rebuild.
    func testLinksNameCurrentFollowsSorted() {
        let json = #"{"follows":["a","b","c","d"],"links":{"ab":[1],"author":[3,0,2,9],"bb":[0,3]},"timestamp":1}"#
        let data = Data(json.utf8)
        // c was unfollowed since the rebuild; 9 is out of range.
        XCTAssertEqual(TrustLinks.bridges(in: data, of: "bb", me: me, current: ["a", "b", "d"]), ["a", "d"])
        XCTAssertEqual(TrustLinks.bridges(in: data, of: "ab", me: me, current: ["a"]), nil)
        XCTAssertEqual(TrustLinks.bridges(in: data, of: "cc", me: me, current: ["a", "b"]), nil)
        // Not hex: never searched for, so it can't match part of a key.
        XCTAssertEqual(TrustLinks.bridges(in: data, of: author, me: me, current: ["a", "d"]), nil)
        XCTAssertEqual(TrustLinks.bridges(in: data, of: "b", me: me, current: ["a", "d"]), nil)
        XCTAssertNil(TrustLinks.bridges(in: Data("{}".utf8), of: "ab", me: me, current: ["b"]))
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
