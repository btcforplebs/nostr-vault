import XCTest
@testable import MediaLogic

/// The account's own reactions: which emoji it sent, and that a removed one
/// stays removed when relays keep serving it.
final class MyReactionTests: XCTestCase {
    private typealias RX = EngagementTracker.ReactionEvent

    private let owner = "owner"
    private let mine = RX(targetId: "note1", pubkey: "owner", eventId: "rx1", content: "🔥")
    private let theirs = RX(targetId: "note1", pubkey: "someone", eventId: "rx2", content: "+")

    func testOwnReactionKeepsItsContentAndEvent() {
        let found = EngagementTracker.detectSelfReactions(reactions: [mine, theirs], ownerHex: owner, retracted: [])
        XCTAssertEqual(found, ["note1": .init(content: "🔥", eventId: "rx1")])
    }

    func testRetractedReactionIsNotTheAccountsAnymore() {
        let found = EngagementTracker.detectSelfReactions(reactions: [mine], ownerHex: owner, retracted: ["rx1"])
        XCTAssertTrue(found.isEmpty)
    }

    func testRetractedReactionIsNotCounted() {
        let stats = EngagementTracker.mergeEngagementCounts(
            reactions: [mine, theirs], repostTargets: [], currentStats: [:], retracted: ["rx1"])
        XCTAssertEqual(stats["note1"]?.reactions, 1)
    }

    func testStateRoundTripsReactions() throws {
        let saved = EngagementTracker.InteractionState(
            likedEventIds: ["note1"], zappedEventIds: [:],
            myReactions: ["note1": .init(content: "🔥", eventId: "rx1")],
            retractedReactionIds: ["rx0"], account: owner)
        let state = try JSONDecoder().decode(EngagementTracker.InteractionState.self,
                                             from: JSONEncoder().encode(saved))
        XCTAssertEqual(state.myReactions["note1"], .init(content: "🔥", eventId: "rx1"))
        XCTAssertEqual(state.retractedReactionIds, ["rx0"])
    }

    /// Files saved before reactions were kept still load, with none.
    func testOlderFileLoadsWithoutReactions() throws {
        let state = try JSONDecoder().decode(EngagementTracker.InteractionState.self,
            from: Data(#"{"likedEventIds":["a"],"zappedEventIds":{},"account":"owner"}"#.utf8))
        XCTAssertEqual(state.likedEventIds, ["a"])
        XCTAssertTrue(state.myReactions.isEmpty)
        XCTAssertTrue(state.retractedReactionIds.isEmpty)
    }
}
