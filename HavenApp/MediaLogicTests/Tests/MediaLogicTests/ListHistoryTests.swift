import XCTest
@testable import MediaLogic

/// The vault's list history as the app reads it (Android twin:
/// `ListHistoryTest.kt`; the shrink table matches haven-go
/// `list_shrink_test.go` case for case).
final class ListHistoryTests: XCTestCase {
    private var serial = 0

    private func list(_ kind: Int, _ items: Int, content: String = "", at: Int64 = 0, first: Int = 0,
                      extra: [[String]] = [], author: String = "me") -> ListVersion {
        serial += 1
        let tags = extra + (first..<(first + items)).map { ["e", "item\($0)"] }
        return ListVersion(id: "id\(serial)", pubkey: author, kind: kind, createdAt: at, tags: tags, content: content)
    }

    private func profile(_ content: String, at: Int64 = 0) -> ListVersion {
        serial += 1
        return ListVersion(id: "p\(serial)", pubkey: "me", kind: 0, createdAt: at, tags: [], content: content)
    }

    func testShrinkRuleTable() {
        let big = String(repeating: "x", count: 2000)
        let cases: [(String, ListVersion, ListVersion, Bool)] = [
            ("emptied", list(10003, 3), list(10003, 0), true),
            ("emptied a one-item list", list(10002, 1), list(10002, 0), true),
            ("fewer than half of 240", list(10003, 240), list(10003, 100), true),
            ("exactly half is an edit", list(10003, 20), list(10003, 10), false),
            ("small list edited down", list(10002, 4), list(10002, 1), false),
            ("nine to one is small", list(3, 9), list(3, 1), false),
            ("ten to four", list(3, 10), list(3, 4), true),
            ("a grow", list(3, 10), list(3, 30), false),
            ("empty to empty", list(3, 0), list(3, 0), false),
            ("private part wiped", list(10000, 2, content: big), list(10000, 2), true),
            ("private part cut by more than half", list(10003, 2, content: big), list(10003, 2, content: String(big.prefix(900))), true),
            ("private part edited", list(10003, 2, content: big), list(10003, 2, content: String(big.prefix(1200))), false),
            ("small private part shortened", list(10003, 2, content: String(big.prefix(400))), list(10003, 2, content: String(big.prefix(100))), false),
            ("kind 3 content is not a private part", list(3, 5, content: big), list(3, 5), false),
            ("profile emptied", profile(#"{"name":"a","about":"b","picture":"c"}"#), profile("{}"), true),
            ("profile fields blanked", profile(#"{"name":"a","about":"b"}"#), profile(#"{"name":"","about":""}"#), true),
            ("profile edited", profile(#"{"name":"a","about":"b"}"#), profile(#"{"name":"z"}"#), false),
            ("title and d are not items", list(30003, 0, extra: [["d", "x"], ["title", "T"]]), list(30003, 0, extra: [["d", "x"]]), false),
        ]
        for (name, prev, next, want) in cases {
            XCTAssertEqual(ListShrinkRule.shrank(prev, next), want, name)
        }
    }

    func testKindSetMatchesTheVault() {
        XCTAssertEqual(ListShrinkRule.protectedKinds, [0, 3, 10000, 10001, 10002, 10003, 10004, 10006, 10007,
                                                       10015, 10030, 10050, 10063, 30000, 30002, 30003])
        XCTAssertFalse(ListShrinkRule.isProtected(1))
        XCTAssertFalse(ListShrinkRule.isProtected(30023))
    }

    func testProfileFieldCount() {
        XCTAssertEqual(ListShrinkRule.itemCount(profile(#"{"name":"a","about":"","picture":"p","bot":false,"x":null}"#)), 3)
        XCTAssertEqual(ListShrinkRule.itemCount(profile("not json")), 0)
    }

    func testHoldsNeedsEveryItemNotTheSameCount() {
        let old = list(10003, 15)
        XCTAssertFalse(ListShrinkRule.holds(list(10003, 15, first: 100), old))
        XCTAssertTrue(ListShrinkRule.holds(list(10003, 16), old))
    }

    func testGroupsPerListNewestFirstOwnAuthorOnly() {
        let a1 = list(30003, 1, at: 1, extra: [["d", "reading"]])
        let a2 = list(30003, 2, at: 2, extra: [["d", "reading"]])
        let b = list(30003, 1, at: 1, extra: [["d", "recipes"]])
        let stranger = list(10003, 3, at: 5, author: "them")
        let note = list(1, 0, at: 5)
        let groups = ListHistory.group([a1, b, a2, a2, stranger, note], author: "me")
        XCTAssertEqual(groups[.init(kind: 30003, d: "reading")]?.map(\.id), [a2.id, a1.id])
        XCTAssertEqual(groups[.init(kind: 30003, d: "recipes")]?.map(\.id), [b.id])
        XCTAssertEqual(groups.count, 2)
    }

    func testLatestWipeOffersTheVersionBefore() {
        let full = list(10003, 24, at: 1), wiped = list(10003, 0, at: 2)
        XCTAssertEqual(ListHistory.latestWipe([wiped, full]), .init(before: full, after: wiped))
        // An edit is no wipe.
        XCTAssertNil(ListHistory.latestWipe([list(10003, 23, at: 3), full]))
        // A wipe that is no longer the newest version is no longer news.
        XCTAssertNil(ListHistory.latestWipe([list(10003, 1, at: 3), wiped, full]))
    }

    /// A late, older copy filed between the list and the wipe: the larger
    /// list is offered (as haven-go keeps it pinned).
    func testLatestWipeOffersTheLargestSinceTheWipeBefore() {
        let full = list(10003, 20, at: 1), late = list(10003, 11, at: 2), wiped = list(10003, 0, at: 3)
        XCTAssertEqual(ListHistory.latestWipe([wiped, late, full])?.before, full)
        // But never across an older wipe.
        let older = list(10003, 40, at: 0), oldWipe = list(10003, 0, at: 1)
        let rebuilt = list(10003, 12, at: 2), again = list(10003, 0, at: 3)
        XCTAssertEqual(ListHistory.latestWipe([again, rebuilt, oldWipe, older])?.before, rebuilt)
    }

    func testDiffAndRestoredList() {
        let old = list(3, 3, content: "old relays"), current = list(3, 2, content: "current relays", first: 2)
        let diff = ListHistory.diff(restoring: old, over: current)
        XCTAssertEqual(diff.comeBack, ["e\u{0}item0", "e\u{0}item1"])
        XCTAssertEqual(diff.go, ["e\u{0}item3"])
        let restored = ListHistory.restored(old, current: current)
        XCTAssertEqual(restored.tags, old.tags)
        XCTAssertEqual(restored.content, "current relays", "kind 3 keeps the current content")
        let mutes = list(10000, 2, content: "ciphertext")
        XCTAssertEqual(ListHistory.restored(mutes, current: list(10000, 0)).content, "ciphertext")
    }

    /// Removing your last bookmark is no banner; a real wipe is (Tron, PR 1568).
    func testBannerNeedsAListOfThreeOrALongPrivatePart() {
        XCTAssertFalse(ListHistory.worthABanner(.init(before: list(10003, 1), after: list(10003, 0))))
        XCTAssertFalse(ListHistory.worthABanner(.init(before: list(10003, 2), after: list(10003, 0))))
        XCTAssertTrue(ListHistory.worthABanner(.init(before: list(10003, 3), after: list(10003, 0))))
        let longPrivate = String(repeating: "x", count: 1000)
        XCTAssertTrue(ListHistory.worthABanner(.init(before: list(10000, 0, content: longPrivate), after: list(10000, 0))))
        XCTAssertFalse(ListHistory.worthABanner(.init(before: list(3, 0, content: longPrivate), after: list(3, 0))), "kind 3 content is not private")
    }

    /// The public diff can be empty while the private part is swapped (Tron, PR 1568).
    func testRestoreSaysWhenItReplacesThePrivatePart() {
        let old = list(10003, 2, content: "old cipher"), current = list(10003, 2, content: "new cipher")
        let diff = ListHistory.diff(restoring: old, over: current)
        XCTAssertTrue(diff.comeBack.isEmpty && diff.go.isEmpty)
        XCTAssertTrue(ListHistory.replacesPrivatePart(old, current: current))
        XCTAssertFalse(ListHistory.replacesPrivatePart(old, current: list(10003, 0, content: "old cipher")))
        XCTAssertFalse(ListHistory.replacesPrivatePart(list(3, 2, content: "a"), current: list(3, 2, content: "b")), "kind 3 keeps the current content")
        XCTAssertTrue(ListHistory.replacesPrivatePart(old, current: nil))
    }
}
