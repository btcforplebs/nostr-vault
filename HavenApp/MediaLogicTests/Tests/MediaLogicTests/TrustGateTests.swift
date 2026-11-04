import XCTest
@testable import MediaLogic

/// Replies, quotes, article comments and live chat follow the Global feed's
/// trust rule (Logen, 2026-11-04: strangers' replies were getting through).
final class TrustGateTests: XCTestCase {
    func testAllowsWebAlwaysAndEveryone() {
        let web: Set<String> = ["friend"]
        XCTAssertTrue(TrustGate.allows("friend", trusted: web, always: []))
        XCTAssertFalse(TrustGate.allows("stranger", trusted: web, always: []))
        XCTAssertTrue(TrustGate.allows("author", trusted: web, always: ["author"]), "the note's author always shows")
        XCTAssertTrue(TrustGate.allows("stranger", trusted: nil, always: []), "shield on Everyone holds nobody back")
    }

    func testFailsClosedWithoutAGraph() {
        XCTAssertFalse(TrustGate.allows("anyone", trusted: [], always: ["me"]), "no graph yet: like Global, nobody passes")
        XCTAssertTrue(TrustGate.allows("me", trusted: [], always: ["me"]))
    }

    func testSplitKeepsOrder() {
        let split = TrustGate.split(["a", "x", "b", "y"], author: { $0 }, trusted: ["a", "b"], always: [])
        XCTAssertEqual(split.inside, ["a", "b"])
        XCTAssertEqual(split.outside, ["x", "y"])
        XCTAssertEqual(TrustGate.split(["x"], author: { $0 }, trusted: nil, always: []).outside, [])
    }

    func testOutsideLabel() {
        XCTAssertEqual(TrustGate.outsideLabel(count: 1, noun: "reply"), "1 reply from outside your web")
        XCTAssertEqual(TrustGate.outsideLabel(count: 3, noun: "reply"), "3 replies from outside your web")
        XCTAssertEqual(TrustGate.outsideLabel(count: 2, noun: "quote"), "2 quotes from outside your web")
    }

    private struct N { let id: String; let parent: String?; let author: String }

    func testThreadSplitFoldsAStrangersWholeBranch() {
        // root <- friend <- author ; root <- stranger <- author (answer to the stranger)
        let notes = [N(id: "f", parent: "root", author: "friend"),
                     N(id: "fa", parent: "f", author: "author"),
                     N(id: "s", parent: "root", author: "stranger"),
                     N(id: "sa", parent: "s", author: "author")]
        let split = ThreadReplyVisibility.split(under: "root", in: notes, id: \.id, parentId: \.parent,
                                                isHidden: { _ in false },
                                                isOutside: { !TrustGate.allows($0.author, trusted: ["friend"], always: ["author"]) })
        XCTAssertEqual(Set(split.inside.map(\.id)), ["f", "fa"])
        XCTAssertEqual(Set(split.outside.map(\.id)), ["s", "sa"], "the author's answer to a folded reply folds with it, never orphaned")
    }

    func testThreadSplitStillDropsHidden() {
        let notes = [N(id: "b", parent: "root", author: "blocked"), N(id: "s", parent: "root", author: "stranger")]
        let split = ThreadReplyVisibility.split(under: "root", in: notes, id: \.id, parentId: \.parent,
                                                isHidden: { $0.author == "blocked" }, isOutside: { $0.author == "stranger" })
        XCTAssertEqual(split.inside.map(\.id), [])
        XCTAssertEqual(split.outside.map(\.id), ["s"], "blocked stays gone, even behind the fold")
    }

    func testArticleWordsGatedCountsKept() {
        let events: [[String: Any]] = [
            ["kind": 1111, "pubkey": "stranger"], ["kind": 1111, "pubkey": "friend"],
            ["kind": 9802, "pubkey": "stranger"], ["kind": 1, "pubkey": "writer"],
            ["kind": 7, "pubkey": "stranger"], ["kind": 9735, "pubkey": "provider"],
        ]
        let kept = ArticleBlockFilter.trustedEvents(events, trusted: ["friend"], always: ["writer"])
        XCTAssertEqual(kept.map { "\($0["kind"]!)/\($0["pubkey"]!)" }, ["1111/friend", "1/writer", "7/stranger", "9735/provider"])
        XCTAssertEqual(ArticleBlockFilter.trustedEvents(events, trusted: nil, always: []).count, events.count)
    }
}
