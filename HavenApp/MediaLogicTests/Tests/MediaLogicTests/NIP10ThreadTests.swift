import XCTest
@testable import MediaLogic

final class NIP10ThreadTests: XCTestCase {
    private func parent(_ tags: [[String]]) -> String? { NIP10Thread.parentEventId(tags: tags) }

    func testQuoteIsNotAReply() {
        // A Primal quote: its only e tag is the quoted note, marked "mention".
        XCTAssertNil(parent([["e", "quoted", "", "mention"], ["client", "Primal iOS"]]))
    }

    func testReplyMarkerWins() {
        XCTAssertEqual(parent([["e", "root", "", "root"], ["e", "parent", "", "reply"]]), "parent")
    }

    func testReplyThatAlsoQuotesPointsAtItsParent() {
        // The mention comes last; positional reading used to pick it.
        XCTAssertEqual(parent([["e", "root", "", "root"], ["e", "parent", "", "reply"], ["e", "quoted", "", "mention"]]), "parent")
    }

    func testDirectReplyToRootWithOnlyARootMarker() {
        XCTAssertEqual(parent([["e", "root", "wss://r", "root"], ["e", "quoted", "", "mention"]]), "root")
    }

    func testPositionalLastUnmarkedTag() {
        XCTAssertEqual(parent([["e", "root"], ["e", "parent"]]), "parent")
        XCTAssertEqual(parent([["e", "root"], ["e", "parent"], ["e", "quoted", "", "mention"]]), "parent")
    }

    func testNoETags() {
        XCTAssertNil(parent([["p", "someone"], ["t", "nostr"]]))
    }
}
