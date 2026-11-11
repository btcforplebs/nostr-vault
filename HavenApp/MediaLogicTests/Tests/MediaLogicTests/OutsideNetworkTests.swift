import XCTest
@testable import MediaLogic

/// The Relay tab's "Outside" filter and a notification tap's routing share
/// this one rule.
final class OutsideNetworkTests: XCTestCase {
    let owner = "owner", friend = "friend", listed = "listed", stranger = "stranger"

    func outside(_ author: String, trusted: Set<String>) -> Bool {
        ContentFilter.isOutside(author: author, owner: owner, whitelist: [owner, listed], trusted: trusted)
    }

    func testStrangerOutsideTheGraphIsOutside() {
        XCTAssertTrue(outside(stranger, trusted: [owner, friend]))
    }

    func testTrustedOwnerAndWhitelistedAreNot() {
        let trusted: Set<String> = [owner, friend]
        XCTAssertFalse(outside(friend, trusted: trusted))
        XCTAssertFalse(outside(owner, trusted: trusted))
        XCTAssertFalse(outside(listed, trusted: trusted))
    }

    /// Before the graph loads a stranger is still outside (fails closed, like
    /// Android and the web); a follow, you and your accounts are not.
    func testEmptyGraphStillPutsAStrangerOutside() {
        let trusted = TrustMap.web(saved: [], follows: [friend])
        XCTAssertTrue(outside(stranger, trusted: trusted))
        XCTAssertTrue(outside(stranger, trusted: []))
        XCTAssertFalse(outside(friend, trusted: trusted))
        XCTAssertFalse(outside(owner, trusted: []))
        XCTAssertFalse(outside(listed, trusted: []))
    }
}
