import XCTest
@testable import MediaLogic

final class GatedArticleTests: XCTestCase {
    private let author = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"

    /// The tags of a real Fanfares article (2026-10-06), ciphertext shortened.
    private func fanfaresTags(ciphertext: String = "AAAA") -> [[String]] {
        [
            ["d", "d6711eb7-0703-48bb-9fd5-61b96e57283c"],
            ["encrypted", "aes-256-gcm", ciphertext, "https://api.fanfares.live/request-key"],
            ["price", "42", "SATS"],
            ["referral", "8"],
            ["zap", author, "wss://fanfares.nostr1.com", "42"],
            ["title", "The Christian Man"],
        ]
    }

    // MARK: Detection

    func testFanfaresArticleIsGated() throws {
        let gated = try XCTUnwrap(GatedArticle(kind: 30023, pubkey: author, tags: fanfaresTags()))
        XCTAssertEqual(gated.priceSats, 42)
    }

    func testOrdinaryArticleIsNotGated() {
        XCTAssertNil(GatedArticle(kind: 30023, pubkey: author, tags: [["d", "x"], ["title", "Free"]]))
    }

    func testNoteKindIsNotGated() {
        XCTAssertNil(GatedArticle(kind: 1, pubkey: author, tags: fanfaresTags()))
    }

    func testMissingKeyURLOrPriceOrFiatIsNotActionable() {
        var tags = fanfaresTags()
        tags[1] = ["encrypted", "aes-256-gcm", "AAAA"]
        XCTAssertNil(GatedArticle(kind: 30023, pubkey: author, tags: tags), "no key URL")

        tags = fanfaresTags().filter { $0.first != "price" }
        XCTAssertNil(GatedArticle(kind: 30023, pubkey: author, tags: tags), "no price")

        tags = fanfaresTags()
        tags[2] = ["price", "5", "USD"]
        XCTAssertNil(GatedArticle(kind: 30023, pubkey: author, tags: tags), "fiat price")

        tags = fanfaresTags()
        tags[1] = ["encrypted", "chacha20", "AAAA", "https://api.fanfares.live/request-key"]
        XCTAssertNil(GatedArticle(kind: 30023, pubkey: author, tags: tags), "unknown cipher")
    }

    // MARK: Decryption

    /// Encrypted by WebCrypto (Node), the API Fanfares' site uses: IV ‖ ct ‖ tag.
    private let webCryptoBlob = "AQIDBAUGBwgJCgsMWVJSyIdkwGGGkd2kTIZsMgf2yoQI++wXRPfUyTlbSWgkrDfVohPZs+M3pLRXdVxSVrYS98ZTHe8/9vfNgHI8mpNeo5hR6fphTQME+3RawQ=="
    private let webCryptoKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    func testDecryptsWebCryptoAESGCM() throws {
        let gated = try XCTUnwrap(GatedArticle(kind: 30023, pubkey: author, tags: fanfaresTags(ciphertext: webCryptoBlob)))
        XCTAssertEqual(gated.decrypt(keyHex: webCryptoKey), "# Whose life is this?\n\nThe full article — with ünïcode ⚡.")
        // The server's body may carry a trailing newline.
        XCTAssertNotNil(gated.decrypt(keyHex: webCryptoKey.uppercased() + "\n"))
    }

    func testWrongKeyOrMalformedKeyDecryptsNothing() throws {
        let gated = try XCTUnwrap(GatedArticle(kind: 30023, pubkey: author, tags: fanfaresTags(ciphertext: webCryptoBlob)))
        XCTAssertNil(gated.decrypt(keyHex: String(repeating: "0", count: 64)))
        XCTAssertNil(gated.decrypt(keyHex: "Payment not verified"))
        XCTAssertNil(gated.decrypt(keyHex: String(webCryptoKey.dropLast(2))))
    }

    // MARK: Teaser

    func testTeaserDropsTheUnlockCallToActionAndLink() {
        let content = "Christian manhood starts with one question: whose life is this?\n\n⚡ Zap 42 sats to unlock the full article on\nhttps://fanfares.io/naddr/naddr1xyz"
        XCTAssertEqual(GatedArticleTeaser.strip(content), "Christian manhood starts with one question: whose life is this?")
    }

    func testTeaserWithoutCallToActionIsUnchanged() {
        XCTAssertEqual(GatedArticleTeaser.strip("Just a teaser."), "Just a teaser.")
    }

}
