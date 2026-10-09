import XCTest
@testable import MediaLogic

/// Likes saved for one account must never show as another account's.
final class InteractionStateAccountTests: XCTestCase {
    private func decode(_ json: String) throws -> EngagementTracker.InteractionState {
        try JSONDecoder().decode(EngagementTracker.InteractionState.self, from: Data(json.utf8))
    }

    func testStampedStateIsOnlyItsOwnAccounts() throws {
        let saved = EngagementTracker.InteractionState(likedEventIds: ["a"], zappedEventIds: [:], account: "npub1second")
        let state = try decode(String(data: JSONEncoder().encode(saved), encoding: .utf8)!)
        XCTAssertEqual(state.account, "npub1second")
        XCTAssertTrue(EngagementTracker.accepts(state, forKey: "npub1second"))
        XCTAssertFalse(EngagementTracker.accepts(state, forKey: "npub1other"))
        XCTAssertFalse(EngagementTracker.accepts(state, forKey: "owner"))
    }

    /// Files from before the stamp may hold another account's likes (a late
    /// account switch saved one account's set under the next), so none is
    /// trusted, the owner's included.
    func testUnstampedStateIsNotTrusted() throws {
        let state = try decode(#"{"likedEventIds":["a"],"zappedEventIds":{}}"#)
        XCTAssertNil(state.account)
        XCTAssertEqual(state.likedEventIds, ["a"])
        XCTAssertFalse(EngagementTracker.accepts(state, forKey: "owner"))
        XCTAssertFalse(EngagementTracker.accepts(state, forKey: "npub1second"))
    }
}
