import XCTest
@testable import MediaLogic

final class NotificationNoteTests: XCTestCase {

    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private let c = String(repeating: "c", count: 64)

    private func event(kind: Int = 1, tags: [[String]] = [], content: String = "gm") -> [String: Any] {
        ["id": a, "pubkey": b, "created_at": 1_800_000_000, "kind": kind,
         "tags": tags, "content": content, "sig": String(repeating: "0", count: 128)]
    }

    func testRoundTripsAWholeEvent() throws {
        let json = try XCTUnwrap(NotificationNote.encode(event(tags: [["p", c]], content: "hi | there\nnext")))
        let decoded = try XCTUnwrap(NotificationNote.decode(json))
        XCTAssertEqual(decoded, NotificationNote.Event(
            id: a, pubkey: b, createdAt: 1_800_000_000, kind: 1, tags: [["p", c]], content: "hi | there\nnext"))
    }

    func testRefusesAnythingThatIsNotAWholeEvent() {
        var missing = event()
        missing["content"] = nil
        XCTAssertNil(NotificationNote.encode(missing))
        var shortId = event()
        shortId["id"] = "abc"
        XCTAssertNil(NotificationNote.encode(shortId))
        XCTAssertNil(NotificationNote.decode("not json"))
        XCTAssertNil(NotificationNote.decode("{\"id\":\"\(a)\"}"))
    }

    /// A long-form post stays out of the notification; the tap loads it by id.
    func testLeavesOutAnOversizedEvent() {
        XCTAssertNil(NotificationNote.encode(event(content: String(repeating: "x", count: NotificationNote.maxEncodedBytes))))
        XCTAssertNotNil(NotificationNote.encode(event(content: String(repeating: "x", count: 1000))))
    }

    /// NIP-25: the last e tag is the post reacted to; earlier ones are its thread.
    func testTargetIsTheLastETag() {
        let tags = [["e", c, "", "root"], ["p", b], ["e", a]]
        XCTAssertEqual(NotificationNote.targetId(type: "reaction", tags: tags), a)
        XCTAssertEqual(NotificationNote.targetId(type: "zap", tags: tags), a)
        XCTAssertEqual(NotificationNote.targetId(type: "repost", tags: tags), a)
    }

    /// Mentions and replies open themselves, and a zap on a profile has no post.
    func testOnlyLikesZapsAndRepostsHaveATarget() {
        let tags = [["e", c]]
        XCTAssertNil(NotificationNote.targetId(type: "mention", tags: tags))
        XCTAssertNil(NotificationNote.targetId(type: "reply", tags: tags))
        XCTAssertNil(NotificationNote.targetId(type: "zap", tags: [["p", b]]))
        XCTAssertNil(NotificationNote.targetId(type: "reaction", tags: [["e", "not-an-id"]]))
    }
}
