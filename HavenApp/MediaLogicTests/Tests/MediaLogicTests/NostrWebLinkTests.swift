import XCTest
@testable import MediaLogic

/// "Open in …" links: each kind of content goes to its one site, as an
/// naddr / nprofile that site can read back.
final class NostrWebLinkTests: XCTestCase {
    private let pubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    func testNprofileMatchesTheNIP19Vector() {
        XCTAssertEqual(
            NostrWebLink.nprofile(pubkey: pubkey, relays: ["wss://r.x.com", "wss://djbas.sadkb.com"]),
            "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
        )
    }

    func testNaddrDecodesBackToTheSameAddress() throws {
        let naddr = try XCTUnwrap(NostrWebLink.naddr(kind: 30023, pubkey: pubkey, identifier: "my-article",
                                                     relays: ["wss://relay.example.com"]))
        XCTAssertTrue(naddr.hasPrefix("naddr1"))
        let decoded = try XCTUnwrap(Bech32.decode(naddr))
        XCTAssertEqual(decoded.hrp, "naddr")
        let parts = try XCTUnwrap(QuoteReference.naddrParts(fromTLV: decoded.data))
        XCTAssertEqual(parts.kind, 30023)
        XCTAssertEqual(parts.pubkey, pubkey)
        XCTAssertEqual(parts.dTag, "my-article")
    }

    func testRecipeGoesToZapCooking() throws {
        let tags = [["d", "pancakes"], ["t", "nostrcooking"], ["title", "Pancakes"]]
        let link = try XCTUnwrap(NostrWebLink.longForm(kind: 30023, pubkey: pubkey, tags: tags))
        let naddr = try XCTUnwrap(NostrWebLink.naddr(kind: 30023, pubkey: pubkey, identifier: "pancakes"))
        XCTAssertEqual(link, .recipe(URL(string: "https://zap.cooking/recipe/\(naddr)")!))
        XCTAssertEqual(link.siteName, "zap.cooking")
    }

    func testArticleGoesToYakiHonne() throws {
        let link = try XCTUnwrap(NostrWebLink.longForm(kind: 30023, pubkey: pubkey, tags: [["d", "essay"]]))
        let naddr = try XCTUnwrap(NostrWebLink.naddr(kind: 30023, pubkey: pubkey, identifier: "essay"))
        XCTAssertEqual(link, .article(URL(string: "https://yakihonne.com/article/\(naddr)")!))
        XCTAssertEqual(link.siteName, "YakiHonne")
    }

    func testLongFormNeedsADTagAndTheLongFormKind() {
        XCTAssertNil(NostrWebLink.longForm(kind: 30023, pubkey: pubkey, tags: [["t", "nostrcooking"]]))
        XCTAssertNil(NostrWebLink.longForm(kind: 1, pubkey: pubkey, tags: [["d", "x"]]))
    }

    func testLiveStreamGoesToZapStreamWithItsRelays() throws {
        let relays = ["wss://relay.zap.stream", "https://not-a-relay", "wss://nos.lol", "wss://third.example"]
        let link = try XCTUnwrap(NostrWebLink.liveStream(authorPubkey: pubkey, identifier: "show", relays: relays))
        XCTAssertEqual(link.url.host, "zap.stream")
        let naddr = link.url.lastPathComponent
        XCTAssertEqual(naddr, NostrWebLink.naddr(kind: 30311, pubkey: pubkey, identifier: "show",
                                                 relays: ["wss://relay.zap.stream", "wss://nos.lol"]))
        // Only ws(s) relays, and no more than two of them.
        let tlv = try XCTUnwrap(Bech32.decode(naddr)).data
        XCTAssertNotNil(tlv.range(of: Data("wss://nos.lol".utf8)))
        XCTAssertNil(tlv.range(of: Data("not-a-relay".utf8)))
        XCTAssertNil(tlv.range(of: Data("third.example".utf8)))
    }

    func testProfileGoesToBrainstorm() throws {
        let link = try XCTUnwrap(NostrWebLink.profile(pubkey: pubkey))
        XCTAssertEqual(link, .profile(URL(string: "https://brainstorm.world/p/\(NostrWebLink.nprofile(pubkey: pubkey)!)")!))
        XCTAssertEqual(link.siteName, "Brainstorm")
    }

    func testBadKeysGiveNoLink() {
        XCTAssertNil(NostrWebLink.profile(pubkey: "abc"))
        XCTAssertNil(NostrWebLink.profile(pubkey: String(repeating: "zz", count: 32)))
        XCTAssertNil(NostrWebLink.liveStream(authorPubkey: "", identifier: "x"))
        XCTAssertNil(NostrWebLink.naddr(kind: -1, pubkey: pubkey, identifier: "x"))
    }
}
