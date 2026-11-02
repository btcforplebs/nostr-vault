import XCTest
@testable import MediaLogic

/// Kind 10003 bookmarks: one tap changes one entry (Android twin: `BookmarkListTest.kt`).
final class BookmarkListTests: XCTestCase {
    let id = String(repeating: "a", count: 64), pk = String(repeating: "b", count: 64)

    func testANoteIsAnEventAndAnArticleAnAddress() {
        XCTAssertEqual(BookmarkList.entry(id: id.uppercased(), pubkey: pk, kind: 1, tags: []), .event(id))
        XCTAssertEqual(BookmarkList.entry(id: id, pubkey: pk.uppercased(), kind: 30023, tags: [["d", "my-post"]]),
                       .address("30023:\(pk):my-post"))
        XCTAssertEqual(BookmarkList.Entry.address("30023:\(pk):a:b").coordinate?.d, "a:b", "a d may hold colons")
    }

    func testAddKeepsEveryOtherTagAndAppendsOnce() {
        let base = [["t", "nostr"], ["e", "old"], ["r", "https://x"], ["unknown", "1", "2"]]
        let added = BookmarkList.toggled(base, .event(id), on: true)
        XCTAssertEqual(added, base + [["e", id]])
        XCTAssertEqual(BookmarkList.toggled(added, .event(id), on: true), added, "already there: unchanged")
    }

    func testRemoveTakesOutEveryCopyOnlyOfThatEntry() {
        let base = [["e", id, "wss://hint"], ["t", "x"], ["e", id.uppercased()], ["e", "other"], ["a", "30023:\(pk):d"]]
        XCTAssertEqual(BookmarkList.toggled(base, .event(id), on: false), [["t", "x"], ["e", "other"], ["a", "30023:\(pk):d"]])
        XCTAssertEqual(BookmarkList.toggled(base, .address("30023:\(pk):d"), on: false).count, 4)
        XCTAssertEqual(BookmarkList.toggled(base, .event("missing"), on: false), base)
    }

    func testEntriesNewestFirstOnceIgnoringOtherTags() {
        let tags = [["e", "one"], ["t", "x"], ["a", "30023:\(pk):d"], ["e", "two"], ["e", "ONE"], ["e", ""]]
        XCTAssertEqual(BookmarkList.entries(tags), [.event("one"), .event("two"), .address("30023:\(pk):d")])
    }

    func testPrivateEntriesFromDecryptedContent() {
        XCTAssertEqual(BookmarkList.privateEntries(plaintext: #"[["e","\#(id)"],["t","x"],["a","30023:\#(pk):d"]]"#),
                       [.address("30023:\(pk):d"), .event(id)])
        XCTAssertEqual(BookmarkList.privateEntries(plaintext: "not json"), [])
    }

    /// A note only in the private part is never offered "Bookmark": a tap would
    /// make it public (Logen 2026-11-02, cd729657).
    func testPrivateOnlyIsBookmarkedPrivately() {
        let e = BookmarkList.Entry.event(id)
        XCTAssertEqual(BookmarkList.menuState(publicTags: [], privateEntries: [e], e), .privately)
        XCTAssertEqual(BookmarkList.menuState(publicTags: [["e", id]], privateEntries: [e], e), .remove, "public wins")
        XCTAssertEqual(BookmarkList.menuState(publicTags: [["e", id]], privateEntries: [], e), .remove)
        XCTAssertEqual(BookmarkList.menuState(publicTags: [["e", "other"]], privateEntries: [.event("x")], e), .add)
    }
}
