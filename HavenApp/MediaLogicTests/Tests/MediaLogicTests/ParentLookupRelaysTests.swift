import XCTest
@testable import MediaLogic

/// The note view asks the `e`-tag hint and the parent author's write relays,
/// as Android does. Case from 2026-11-22: a nostr.wine reply whose parent
/// lives only on relay.ditto.pub.
final class ParentLookupRelaysTests: XCTestCase {
    private let parent = String(repeating: "7", count: 64)
    private let author = String(repeating: "0", count: 64)
    private let known = ["ws://127.0.0.1:4869", "wss://nostr.wine/"]

    func testHintAndAuthorOutboxAreAsked() {
        let tags = [["e", parent, "wss://relay.ditto.pub/", "root", author], ["p", author, "wss://relay.ditto.pub/"]]
        let extra = ParentLookupRelays.extraRelays(tags: tags, replyToPubkey: author, known: known) {
            $0 == self.author ? ["wss://relay.ditto.pub", "wss://other.example"] : nil
        }
        XCTAssertEqual(extra, ["wss://relay.ditto.pub/", "wss://other.example"])
    }

    func testOurOwnRelaysAndMentionsAreNotAddedTwice() {
        let tags = [["e", parent, "wss://NOSTR.wine", "reply"], ["e", parent, "wss://mention.example", "mention"]]
        XCTAssertEqual(ParentLookupRelays.extraRelays(tags: tags, replyToPubkey: nil, known: known) { _ in nil }, [])
    }

    func testEmptyAuthorSlotFallsBackToReplyTarget() {
        let tags = [["e", parent, "", "reply"]]
        XCTAssertEqual(ParentLookupRelays.authors(tags: tags, replyToPubkey: author), [author])
        let extra = ParentLookupRelays.extraRelays(tags: tags, replyToPubkey: author, known: known) { _ in ["wss://out.example"] }
        XCTAssertEqual(extra, ["wss://out.example"])
    }

    func testBadHintsSkippedAndTotalCapped() {
        var tags = [["e", parent, "https://not-a-relay", "root"]]
        for i in 0..<20 { tags.append(["e", String(repeating: "\(i % 10)", count: 64), "wss://r\(i).example"]) }
        let extra = ParentLookupRelays.extraRelays(tags: tags, replyToPubkey: nil, known: []) { _ in nil }
        XCTAssertEqual(extra.count, ParentLookupRelays.maxExtra)
        XCTAssertFalse(extra.contains("https://not-a-relay"))
    }

    /// 2026-11-26: a Nostr Vault iOS kind 1111 reply in a Mostr thread. Its
    /// parent `e` hint was the poster's own phone relay; only the `E` root
    /// named relay.ditto.pub, and the authors sit in the fourth slot.
    func testCommentRootHintLoopbackSkippedAndSlotFourAuthors() {
        let root = String(repeating: "e", count: 64), rootAuthor = String(repeating: "a", count: 64)
        let tags = [
            ["E", root, "wss://relay.ditto.pub/", rootAuthor], ["K", "1"], ["P", rootAuthor],
            ["e", parent, "wss://127.0.0.1:3355", author], ["k", "1111"], ["p", author],
        ]
        XCTAssertEqual(ParentLookupRelays.hints(tags), [
            .init(id: root, relay: "wss://relay.ditto.pub/", author: rootAuthor),
            .init(id: parent, relay: nil, author: author),
        ])
        XCTAssertEqual(ParentLookupRelays.authors(tags: tags, replyToPubkey: nil), [rootAuthor, author])
        XCTAssertEqual(ParentLookupRelays.extraRelays(tags: tags, replyToPubkey: nil, known: []) { _ in nil },
                       ["wss://relay.ditto.pub/"])
    }

    func testLANAndLoopbackHintsAreNotReachable() {
        for raw in ["ws://127.0.0.1:3355", "wss://localhost:4869", "ws://192.168.1.20:3355", "wss://box.local", "ws://[::1]:3355", "wss://10.0.0.4"] {
            XCTAssertNil(ParentLookupRelays.reachableHint(raw), raw)
        }
        XCTAssertEqual(ParentLookupRelays.reachableHint("wss://relay.mostr.pub"), "wss://relay.mostr.pub")
        XCTAssertNil(ParentLookupRelays.reachableHint("https://relay.mostr.pub"))
    }

    func testNIP10MarkerIsNotReadAsAuthor() {
        XCTAssertNil(ParentLookupRelays.author(in: ["e", parent, "wss://a.example", "reply"]))
        XCTAssertEqual(ParentLookupRelays.author(in: ["e", parent, "wss://a.example", "reply", author]), author)
    }
}
