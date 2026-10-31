import XCTest
@testable import MediaLogic

final class LiveStreamShareTests: XCTestCase {
    private let service = String(repeating: "b2", count: 32)

    func testLinkIsTheStreamsNaddrOnThePublicPostPage() throws {
        let naddr = try XCTUnwrap(LiveStreamShare.naddr(authorPubkey: service, identifier: "show-1",
                                                        relays: ["wss://relay.zap.stream"]))
        XCTAssertTrue(naddr.hasPrefix("naddr1"))
        XCTAssertEqual(LiveStreamShare.link(naddr: naddr)?.absoluteString,
                       "https://nostrvault.app/thread/\(naddr)")
        // The naddr names the event that exists: the signer's key, kind 30311.
        let parts = try XCTUnwrap(Bech32.decode(naddr))
        XCTAssertEqual(parts.hrp, "naddr")
    }

    /// Who is live and the naddr, nothing else: the card draws the current
    /// title and picture, so the note never names a show that has ended.
    func testNoteIsLiveNowHostThenTheNaddr() {
        XCTAssertEqual(LiveStreamShare.noteText(hostName: "The Lot Radio", naddr: "naddr1abc"),
                       "Live now: The Lot Radio\n\nnostr:naddr1abc")
        XCTAssertFalse(LiveStreamShare.noteText(hostName: "Ann", naddr: "naddr1abc").contains("http"))
    }

    func testNoteWithoutNaddrStillNamesTheHost() {
        XCTAssertEqual(LiveStreamShare.noteText(hostName: "Ann", naddr: nil), "Live now: Ann")
    }

    func testQuoteTagNamesTheStreamAddressOnce() throws {
        let naddr = try XCTUnwrap(LiveStreamShare.naddr(authorPubkey: service, identifier: "show-1", relays: []))
        let text = LiveStreamShare.noteText(hostName: "Ann", naddr: naddr) + "\nagain nostr:\(naddr)"
        XCTAssertEqual(LiveStreamShare.quoteTags(in: text, relayHint: "wss://r.example"),
                       [["q", "30311:\(service):show-1", "wss://r.example"]])
    }

    func testQuoteTagSkipsOtherAddressableKinds() throws {
        let article = try XCTUnwrap(NostrWebLink.naddr(kind: 30023, pubkey: service, identifier: "post"))
        XCTAssertEqual(LiveStreamShare.quoteTags(in: "read nostr:\(article)"), [])
    }

    // MARK: - Chat media

    func testPhotoGifAndVideoLinksLeaveTheTextInOrder() {
        let parts = LiveChatMedia.split("""
        look https://a.example/x.jpg nice
        https://a.example/y.gif
        https://a.example/z.mp4
        """)
        XCTAssertEqual(parts.text, "look nice")
        XCTAssertEqual(parts.media.map(\.lastPathComponent), ["x.jpg", "y.gif", "z.mp4"])
    }

    /// A stream link or a web page stays text: an HLS player inside the chat
    /// of a stream would be a second broadcast.
    func testStreamAndPageLinksStayInTheText() {
        let text = "https://cdn.example/live/index.m3u8 https://zap.stream/naddr1x"
        let parts = LiveChatMedia.split(text)
        XCTAssertEqual(parts.text, text)
        XCTAssertTrue(parts.media.isEmpty)
    }

    /// Every tile is a fetch by every viewer from a host the sender picked.
    func testMediaStopsAtTheCapAndTheRestStaysText() {
        let links = (1...6).map { "https://h\($0).example/p.jpg" }
        let parts = LiveChatMedia.split(links.joined(separator: " "))
        XCTAssertEqual(parts.media.map(\.absoluteString), Array(links.prefix(LiveChatMedia.maxMedia)))
        XCTAssertEqual(parts.text, links.dropFirst(LiveChatMedia.maxMedia).joined(separator: " "))
    }

    func testRepeatedLinkShowsOnce() {
        let parts = LiveChatMedia.split("https://a.example/x.png https://a.example/x.png")
        XCTAssertEqual(parts.media.count, 1)
        XCTAssertEqual(parts.text, "")
    }
}
