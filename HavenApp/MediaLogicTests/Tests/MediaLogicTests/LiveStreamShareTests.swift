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

    /// Each link on its own line after the title, so another app's parser
    /// finds the picture, the playable HLS and the naddr quote.
    func testNoteCarriesTitlePictureStreamAndNaddrEachOnItsOwnLine() {
        let text = LiveStreamShare.noteText(
            title: "  Night radio ",
            hostName: "Ann",
            pictureURL: URL(string: "https://img.example/cover.jpg"),
            streamingURL: URL(string: "https://cdn.example/live/index.m3u8"),
            naddr: "naddr1abc")
        XCTAssertEqual(text, """
        Night radio, live now with Ann

        https://img.example/cover.jpg
        https://cdn.example/live/index.m3u8
        nostr:naddr1abc
        """)
    }

    func testNoteWithoutTitleOrLinksStillNamesTheHost() {
        XCTAssertEqual(LiveStreamShare.noteText(title: nil, hostName: "Ann", pictureURL: nil,
                                                streamingURL: nil, naddr: nil),
                       "Ann is live now")
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

    func testRepeatedLinkShowsOnce() {
        let parts = LiveChatMedia.split("https://a.example/x.png https://a.example/x.png")
        XCTAssertEqual(parts.media.count, 1)
        XCTAssertEqual(parts.text, "")
    }
}
