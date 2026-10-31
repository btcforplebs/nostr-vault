import XCTest
@testable import MediaLogic

final class LiveNoteCleanupTests: XCTestCase {
    private let service = String(repeating: "b2", count: 32)
    private let cover = URL(string: "https://img.example/cover.png")!
    private let playlist = URL(string: "https://livepeercdn.studio/hls/abc/index.m3u8")!

    private func liveNaddr() throws -> String {
        try XCTUnwrap(LiveStreamShare.naddr(authorPubkey: service, identifier: "lot", relays: []))
    }

    /// Logen's note from Android's old share: heading, cover, playlist, naddr.
    /// It ends as the heading alone above the card.
    func testLogensLiveNoteKeepsOnlyTheHeading() throws {
        let naddr = try liveNaddr()
        let body = LiveNoteCleanup.Body(
            content: "Live now: The Lot Radio: Love Injection\n\(cover.absoluteString)\n\(playlist.absoluteString)\nnostr:\(naddr)",
            mediaURLs: [cover], linkURLs: [playlist])
        let tags = [["d", "lot"], ["image", cover.absoluteString], ["streaming", playlist.absoluteString]]
        let cleaned = LiveNoteCleanup.clean(body, streamURLs: LiveNoteCleanup.streamURLs(tags: tags))
        XCTAssertEqual(cleaned, LiveNoteCleanup.Body(content: "Live now: The Lot Radio: Love Injection",
                                                     mediaURLs: [], linkURLs: []))
    }

    /// Before the stream event arrives the playlist still goes; the cover
    /// only goes once the event says it is the stream's picture.
    func testPlaylistGoesBeforeTheStreamIsKnownPictureWaits() throws {
        let naddr = try liveNaddr()
        let body = LiveNoteCleanup.Body(content: "Live\n\n\(cover.absoluteString)\n\(playlist.absoluteString)\n\nnostr:\(naddr)",
                                        mediaURLs: [cover], linkURLs: [playlist])
        let cleaned = LiveNoteCleanup.clean(body)
        XCTAssertEqual(cleaned.linkURLs, [])
        XCTAssertEqual(cleaned.mediaURLs, [cover])
        XCTAssertEqual(cleaned.content, "Live\n\n\(cover.absoluteString)")
    }

    func testNewShareFormatEndsAsTheHeading() throws {
        let text = LiveStreamShare.noteText(hostName: "Ann", naddr: try liveNaddr())
        let cleaned = LiveNoteCleanup.clean(.init(content: text, mediaURLs: [], linkURLs: []))
        XCTAssertEqual(cleaned.content, "Live now: Ann")
    }

    /// The owner's own words and other links stay.
    func testOtherTextAndLinksStay() throws {
        let naddr = try liveNaddr()
        let page = URL(string: "https://example.com/show")!
        let body = LiveNoteCleanup.Body(content: "Tune in!\n\(page.absoluteString)\n\nnostr:\(naddr)\n\nSee you there.",
                                        mediaURLs: [], linkURLs: [page])
        let cleaned = LiveNoteCleanup.clean(body)
        XCTAssertEqual(cleaned.content, "Tune in!\n\(page.absoluteString)\n\nSee you there.")
        XCTAssertEqual(cleaned.linkURLs, [page])
    }

    /// No live reference, no change: a playlist link in an ordinary note stays.
    func testNoteWithoutLiveReferenceIsUnchanged() throws {
        let article = try XCTUnwrap(NostrWebLink.naddr(kind: 30023, pubkey: service, identifier: "post"))
        let body = LiveNoteCleanup.Body(content: "\(playlist.absoluteString)\nnostr:\(article)",
                                        mediaURLs: [], linkURLs: [playlist])
        XCTAssertEqual(LiveNoteCleanup.clean(body), body)
    }

    func testLiveQuoteIdIsTheFeedCoordinate() throws {
        XCTAssertEqual(LiveNoteCleanup.liveQuoteIds(in: "nostr:\(try liveNaddr())"),
                       ["naddr:30311:\(service):lot"])
    }
}
