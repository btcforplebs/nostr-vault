import XCTest
@testable import MediaLogic

final class LocalDvmFeedTests: XCTestCase {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    func testFollowsJSONIsSortedLowercaseHexOnly() {
        let json = LocalDvmFeed.followsJSON([b, a.uppercased(), a, "npub1xyz", ""])
        XCTAssertEqual(json, "[\"\(a)\",\"\(b)\"]")
        XCTAssertEqual(LocalDvmFeed.followsJSON([]), "[]")
    }

    func testOnlyCatchUpSkipsTheTrustGraph() {
        XCTAssertFalse(LocalDvmFeed.catchUp.needsTrustGraph)
        XCTAssertTrue(LocalDvmFeed.popular.needsTrustGraph)
        XCTAssertTrue(LocalDvmFeed.underrated.needsTrustGraph)
    }

    /// FeedMode maps onto these by raw value: a rename on one side would
    /// silently drop the feed from the local DVM path.
    func testRawValuesMatchTheFeedPicker() {
        XCTAssertEqual(LocalDvmFeed.allCases.map(\.rawValue), ["Popular", "Catch Up", "Underrated"])
    }
}
