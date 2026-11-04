import XCTest
@testable import MediaLogic

/// Likes, reposts and zaps on your notes that aren't in memory yet (Logen
/// 2026-11-04: Live Vault showed only zaps at first, the rest late or never;
/// RESEARCH/NV_LIVE_VAULT_LOAD_ORDER.md).
final class VaultActivityPendingTargetTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let ann = String(repeating: "b", count: 64)
    private let bob = String(repeating: "c", count: 64)
    private let noteKinds: Set<Int> = [1, 6, 30023, 1111, 9802, 1068]

    private func event(_ id: String, _ pubkey: String, kind: Int = 1, at: Int64,
                       content: String = "", tags: [[String]] = []) -> VaultActivity.Event {
        VaultActivity.Event(id: id, pubkey: pubkey, kind: kind, createdAt: at, content: content, tags: tags, images: [])
    }

    private func zap(_ id: String, from sender: String, on note: String, at: Int64) -> VaultActivity.Event {
        let request: [String: Any] = ["pubkey": sender, "content": "", "tags": [["p", me], ["e", note]], "kind": 9734]
        let json = String(data: try! JSONSerialization.data(withJSONObject: request), encoding: .utf8)!
        return event(id, "lnurlprovider", kind: 9735, at: at, tags: [["p", me], ["description", json], ["e", note]])
    }

    private func build(_ events: [VaultActivity.Event]) -> [VaultActivity] {
        VaultActivity.build(events: events, owner: me, noteKinds: noteKinds)
    }

    private var inbound: [VaultActivity.Event] {
        [zap("z1", from: ann, on: "post", at: 200),
         // NIP-25/18: the reacted-to note's author is the last p.
         event("like", bob, kind: 7, at: 210, content: "+", tags: [["e", "post"], ["p", ann], ["p", me]]),
         event("rp", bob, kind: 6, at: 220, tags: [["e", "post"], ["p", me]]),
         event("reply", ann, at: 230, content: "hi", tags: [["e", "post"], ["p", me]])]
    }

    func testLikesRepostsAndZapsShowBeforeYourNoteLandsAndKeepTheirIdsWhenItDoes() {
        let before = build(inbound)
        XCTAssertEqual(Set(before.map(\.kind)), [.reply, .reaction, .repost, .zap], "not only zaps and replies")
        let after = build(inbound + [event("post", me, at: 100, content: "my post")])
        let ids = { (lines: [VaultActivity]) in Set(lines.filter { $0.kind != .reply }.map(\.id)) }
        XCTAssertEqual(ids(before), ids(after), "a line keeps its slot once the note arrives")
        XCTAssertEqual(ids(after), ["reaction-post", "repost-post", "zap-post"])
        XCTAssertTrue(before.filter { $0.kind == .reaction }.allSatisfy { $0.preview.isEmpty })
        XCTAssertEqual(after.first { $0.kind == .reaction }?.preview, "my post")
        XCTAssertEqual(after.first { $0.kind == .reaction }?.openId, "post")
    }

    func testANoteKnownToBeSomeoneElsesOrNotNamingYouGetsNoLine() {
        // In memory and somebody else's: not a like of yours.
        let theirs = build([event("post", ann, at: 100), event("like", bob, kind: 7, at: 210, content: "+", tags: [["e", "post"], ["p", me]])])
        XCTAssertTrue(theirs.filter { $0.kind == .reaction }.isEmpty)
        // Not in memory, and its author (last p) is someone else.
        let other = build([event("like", bob, kind: 7, at: 210, content: "+", tags: [["e", "x"], ["p", me], ["p", ann]]),
                           event("rp", bob, kind: 6, at: 220, tags: [["e", "x"], ["p", ann]])])
        XCTAssertTrue(other.isEmpty)
        // A zap on someone else's note (in memory) stays its own line, as before.
        let zapOnTheirs = build([event("post", ann, at: 100), zap("z1", from: bob, on: "post", at: 200)])
        XCTAssertEqual(zapOnTheirs.map(\.id), ["z1"])
    }

    func testMissingTargetsNamesTheNotesToFetchOnceEach() {
        let have = Set(inbound.map(\.id))
        let before = build(inbound)
        XCTAssertEqual(VaultActivity.missingTargets(in: before, have: have), ["post"])
        let after = build(inbound + [event("post", me, at: 100)])
        XCTAssertEqual(VaultActivity.missingTargets(in: after, have: have.union(["post"])), [])
        // A zap with words is its own line (id = the receipt): nothing to fetch for it.
        XCTAssertEqual(VaultActivity.missingTargets(in: [VaultActivity(id: "z9", kind: .zap, actors: [ann], createdAt: 1,
                                                                        openId: "n", preview: "thanks")], have: []), [])
    }
}
