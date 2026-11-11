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
    /// Logen 2026-11-11: Underrated ran out onto the background.
    func testEndOfListOnlyOnALoadedLocalDvmFeedWithNotes() {
        XCTAssertTrue(LocalDvmFeed.showsEndOfList(mode: .underrated, hasNotes: true, isLoading: false))
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: nil, hasNotes: true, isLoading: false), "Home, Articles, Global")
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: .popular, hasNotes: false, isLoading: false), "empty state owns it")
        XCTAssertFalse(LocalDvmFeed.showsEndOfList(mode: .catchUp, hasNotes: true, isLoading: true))
    }

    func testEndOfListCopyIsPerFeed() {
        XCTAssertEqual(LocalDvmFeed.underrated.endOfListStatus + " Pull to refresh",
                       "That's today's underrated list. Pull to refresh")
        XCTAssertEqual(Set(LocalDvmFeed.allCases.map(\.endOfListStatus)).count, 3)
    }
}
