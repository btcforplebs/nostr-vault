import XCTest
@testable import MediaLogic

final class ArticleTallyTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)
    private let author = String(repeating: "b", count: 64)
    private var coord: String { "30023:\(author):my-post" }
    private var n = 0

    private func event(_ kind: Int, _ tags: [[String]], content: String = "hi", pubkey: String? = nil,
                       at time: Double = 1_700_000_000) -> [String: Any] {
        n += 1
        return ["id": "ev\(n)", "kind": kind, "pubkey": pubkey ?? "p\(n)", "content": content,
                "tags": tags, "created_at": NSNumber(value: time + Double(n))]
    }

    private func tally(_ events: [[String: Any]]) -> ArticleTally {
        ArticleEngagement.tally(events, articleId: id, coordinate: coord, now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testLikesCountPeopleNotReactionsAndSkipDislikes() {
        let t = tally([
            event(7, [["a", coord]], content: "+", pubkey: "alice"),
            event(7, [["e", id]], content: "🔥", pubkey: "alice"),
            event(7, [["e", id]], content: "+", pubkey: "bob"),
            event(7, [["e", id]], content: "-", pubkey: "carol"),
            event(7, [["e", "other"]], content: "+", pubkey: "dave"),
        ])
        XCTAssertEqual(t.likers, ["alice", "bob"])
    }

    func testZapsSumTheRequestedAmount() {
        let request = #"{"kind":9734,"tags":[["amount","21000"]]}"#
        let t = tally([
            event(9735, [["e", id], ["description", request]]),
            event(9735, [["a", coord], ["amount", "1000000"]]),
            event(9735, [["e", "other"], ["description", request]]),
        ])
        XCTAssertEqual(t.zaps, 2)
        XCTAssertEqual(t.zapSats, 21 + 1000)
    }

    func testCommentsSplitTopLevelFromReplies() {
        let top = event(1111, [["A", coord], ["K", "30023"], ["a", coord], ["k", "30023"]])
        let reply = event(1111, [["A", coord], ["K", "30023"], ["e", top["id"] as! String], ["k", "1111"]])
        let legacy = event(1, [["e", id, "", "root"], ["a", coord]])
        let legacyReply = event(1, [["e", id, "", "root"], ["e", legacy["id"] as! String, "", "reply"]])
        let mention = event(1, [["e", id, "", "mention"]])
        let t = tally([top, reply, legacy, legacyReply, mention])
        XCTAssertEqual(t.commentCount, 4)
        XCTAssertEqual(t.topLevelComments.map { $0["id"] as? String }, [top["id"] as? String, legacy["id"] as? String])
        XCTAssertEqual(t.replyCounts[top["id"] as! String], 1)
        XCTAssertEqual(t.replyCounts[legacy["id"] as! String], 1)
    }

    func testDuplicatesAndFutureDatedEventsAreDropped() {
        let like = event(7, [["e", id]], pubkey: "alice")
        let future = event(1111, [["a", coord]], at: 2_000_000_000)
        let t = tally([like, like, future])
        XCTAssertEqual(t.likers.count, 1)
        XCTAssertEqual(t.commentCount, 0)
    }

    func testFiltersAskByIdAndCoordinateAndCommentRoot() {
        let filters = ArticleEngagement.engagementFilters(id: id, coordinate: coord)
        XCTAssertTrue(filters.contains { ($0["#E"] as? [String]) == [id] })
        XCTAssertTrue(filters.contains { ($0["#A"] as? [String]) == [coord] })
        XCTAssertEqual(ArticleEngagement.engagementFilters(id: id, coordinate: nil).count, 2)
    }
}
