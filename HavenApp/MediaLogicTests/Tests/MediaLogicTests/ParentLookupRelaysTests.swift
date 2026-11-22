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
}
