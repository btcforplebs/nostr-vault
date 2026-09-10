import XCTest
@testable import MediaLogic

final class BunkerURITests: XCTestCase {
    let signer = String(repeating: "ab", count: 32)

    private func uri(_ suffix: String = "?relay=wss://relay.example.com") -> String {
        "bunker://\(signer)\(suffix)"
    }

    // MARK: - parse

    func testParsesStandardURI() {
        let info = BunkerURI.parse(uri())
        XCTAssertEqual(info?.signerPubkey, signer)
        XCTAssertEqual(info?.relayURL, "wss://relay.example.com")
        XCTAssertEqual(info?.secret, "")
    }

    func testParsesSecret() {
        let info = BunkerURI.parse(uri("?relay=wss://relay.example.com&secret=hunter2"))
        XCTAssertEqual(info?.secret, "hunter2")
    }

    func testAcceptsSingleSlashSpelling() {
        let info = BunkerURI.parse("bunker:\(signer)?relay=wss://relay.example.com")
        XCTAssertEqual(info?.signerPubkey, signer)
    }

    func testRejectsMissingRelay() {
        XCTAssertNil(BunkerURI.parse(uri("")))
    }

    func testRejectsEmptyRelay() {
        XCTAssertNil(BunkerURI.parse(uri("?relay=")))
    }

    func testRejectsShortPubkey() {
        XCTAssertNil(BunkerURI.parse("bunker://abcdef?relay=wss://relay.example.com"))
    }

    func testRejectsNonHexPubkey() {
        XCTAssertNil(BunkerURI.parse("bunker://\(String(repeating: "zz", count: 32))?relay=wss://relay.example.com"))
    }

    func testRejectsOtherSchemes() {
        XCTAssertNil(BunkerURI.parse("nostrconnect://\(signer)?relay=wss://relay.example.com"))
        XCTAssertNil(BunkerURI.parse("npub1abcdef"))
        XCTAssertNil(BunkerURI.parse("https://example.com"))
        XCTAssertNil(BunkerURI.parse(""))
    }

    // MARK: - normalized (what a QR scan is judged by)

    func testNormalizedKeepsAStandardURI() {
        XCTAssertEqual(BunkerURI.normalized(uri()), uri())
    }

    func testNormalizedTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(BunkerURI.normalized("  \(uri())\n"), uri())
    }

    func testNormalizedStripsNostrPrefix() {
        XCTAssertEqual(BunkerURI.normalized("nostr:\(uri())"), uri())
        XCTAssertEqual(BunkerURI.normalized("NOSTR:\(uri())"), uri())
    }

    func testNormalizedExpandsSingleSlashSpelling() {
        XCTAssertEqual(BunkerURI.normalized("bunker:\(signer)?relay=wss://relay.example.com"), uri())
    }

    func testNormalizedRejectsCodesThatAreNotBunkerStrings() {
        // The QR codes a signer app is most likely to show instead.
        XCTAssertNil(BunkerURI.normalized("npub1w0rthl3ss"))
        XCTAssertNil(BunkerURI.normalized("nostr:npub1w0rthl3ss"))
        XCTAssertNil(BunkerURI.normalized("nostrconnect://\(signer)?relay=wss://relay.example.com"))
        XCTAssertNil(BunkerURI.normalized("https://njump.me/npub1abc"))
        XCTAssertNil(BunkerURI.normalized("lnbc1u1p..."))
        XCTAssertNil(BunkerURI.normalized(""))
    }

    func testNormalizedRejectsAWellFormedPrefixWithNoRelay() {
        // Starts with bunker:// but Connect could never use it.
        XCTAssertNil(BunkerURI.normalized("bunker://\(signer)"))
    }
}
