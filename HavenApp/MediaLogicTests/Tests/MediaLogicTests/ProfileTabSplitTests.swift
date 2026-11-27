import XCTest
@testable import MediaLogic

final class ProfileTabSplitTests: XCTestCase {
    private let pinned = ["notes", "media", "replies"]

    func testThreeOnTheBarRestBehindMore() {
        let visible = ["notes", "media", "replies", "reposts", "tagged"]
        let s = ProfileTabSplit.split(visible: visible, pinned: pinned)
        XCTAssertEqual(s.bar, ["notes", "media", "replies"])
        XCTAssertEqual(s.more, ["reposts", "tagged"])
    }

    func testLateKindsGoBehindMoreInTabOrder() {
        let visible = ["notes", "media", "replies", "reposts", "tagged", "articles", "music", "shop"]
        let s = ProfileTabSplit.split(visible: visible, pinned: pinned)
        XCTAssertEqual(s.bar, ["notes", "media", "replies"])
        XCTAssertEqual(s.more, ["reposts", "tagged", "articles", "music", "shop"])
    }

    func testFourOrFewerKindsNeedNoMore() {
        let visible = ["notes", "media", "replies", "reposts"]
        let s = ProfileTabSplit.split(visible: visible, pinned: pinned)
        XCTAssertEqual(s.bar, visible)
        XCTAssertTrue(s.more.isEmpty)
    }

    func testMissingPinnedKindFreesItsSlot() {
        let visible = ["notes", "replies", "reposts", "tagged", "shop"]
        let s = ProfileTabSplit.split(visible: visible, pinned: pinned)
        XCTAssertEqual(s.bar, ["notes", "replies", "reposts"])
        XCTAssertEqual(s.more, ["tagged", "shop"])
    }

    func testEveryVisibleKindIsReachableOnce() {
        let visible = ["notes", "media", "replies", "reposts", "tagged", "articles", "divines", "music", "shop"]
        let s = ProfileTabSplit.split(visible: visible, pinned: pinned)
        XCTAssertEqual(s.bar.count, ProfileTabSplit.barSlots)
        XCTAssertEqual((s.bar + s.more).sorted(), visible.sorted())
    }
}
