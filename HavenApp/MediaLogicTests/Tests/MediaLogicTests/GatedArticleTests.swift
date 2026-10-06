import XCTest
@testable import MediaLogic

final class GatedArticleTests: XCTestCase {
    private let author = "adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1"
    private let other = String(repeating: "c", count: 64)

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
        XCTAssertEqual(gated.shares, [.init(pubkey: author, relay: "wss://fanfares.nostr1.com", sats: 42)])
        XCTAssertEqual(gated.receiptRelays, ["wss://fanfares.nostr1.com"])
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

    // MARK: Price split (mirrors Fanfares' own check)

    func testNoZapTagPaysTheAuthor() {
        XCTAssertEqual(GatedArticle.split(price: 42, authorPubkey: author, tags: []),
                       [.init(pubkey: author, relay: nil, sats: 42)])
    }

    func testWeightedSplitRoundsEachShareUp() {
        let tags = [["zap", author, "", "2"], ["zap", other, "", "1"]]
        let shares = GatedArticle.split(price: 10, authorPubkey: author, tags: tags)
        // 2/3 × 10 = 6.67 → 7, 1/3 × 10 = 3.33 → 4: paying both covers the check.
        XCTAssertEqual(shares.map(\.sats), [7, 4])
    }

    func testRepeatedRecipientWeightsAreSummed() {
        let tags = [["zap", author, "", "1"], ["zap", other, "", "1"], ["zap", author, "", "2"]]
        let shares = GatedArticle.split(price: 8, authorPubkey: author, tags: tags)
        XCTAssertEqual(shares.map(\.pubkey), [author, other])
        XCTAssertEqual(shares.map(\.sats), [6, 2])
    }

    func testZeroWeightCountsAsOne() {
        let tags = [["zap", author, "", "0"], ["zap", other, "", "1"]]
        XCTAssertEqual(GatedArticle.split(price: 2, authorPubkey: author, tags: tags).map(\.sats), [1, 1])
    }

    // MARK: Key request

    func testFanfaresBackendIsReachedThroughItsPublicProxy() throws {
        let gated = try XCTUnwrap(GatedArticle(kind: 30023, pubkey: author, tags: fanfaresTags()))
        XCTAssertEqual(gated.requestURL.absoluteString, "https://fanfares.io/api/request-key")
        // The signed event still names the URL from the tag.
        XCTAssertEqual(gated.httpAuthTags, [["u", "https://api.fanfares.live/request-key"], ["method", "GET"]])
    }

    func testOtherKeyServersAreUsedAsTagged() throws {
        var tags = fanfaresTags()
        tags[1] = ["encrypted", "aes-256-gcm", "AAAA", "https://keys.example.com/k"]
        let gated = try XCTUnwrap(GatedArticle(kind: 30023, pubkey: author, tags: tags))
        XCTAssertEqual(gated.requestURL.absoluteString, "https://keys.example.com/k")
    }

    func testNaddrTLVMatchesTheRealArticleAddress() {
        // Bech32-decoded payload of the naddr Fanfares links to for this article.
        let expected = "0304000075470220adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e101197773733a2f2f66616e66617265732e6e6f737472312e636f6d002464363731316562372d303730332d343862622d396664352d363162393665353732383363"
        let tlv = GatedArticle.naddrTLV(identifier: "d6711eb7-0703-48bb-9fd5-61b96e57283c",
                                        relay: "wss://fanfares.nostr1.com", pubkey: author, kind: 30023)
        XCTAssertEqual(tlv?.map { String(format: "%02x", $0) }.joined(), expected)
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

    func testUnlockURLIsTheCallToActionLinkNotATeaserImage() {
        let content = "![cover](https://img.example/a.png)\n\nTeaser.\n\n⚡ Zap 42 sats to unlock the full article on\nhttps://fanfares.io/naddr/naddr1xyz"
        XCTAssertEqual(GatedArticleTeaser.unlockURL(content)?.absoluteString, "https://fanfares.io/naddr/naddr1xyz")
        XCTAssertNil(GatedArticleTeaser.unlockURL("https://img.example/a.png only"))
    }
}
