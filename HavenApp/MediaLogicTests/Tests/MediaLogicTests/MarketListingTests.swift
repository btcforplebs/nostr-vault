import XCTest
@testable import MediaLogic

/// Event shapes captured from nostr.wine, relay.damus.io and relay.primal.net
/// on 2026-10-04 (kinds 30018/30020/30402, limit 200 each).
final class MarketListingTests: XCTestCase {
    private func listing(kind: Int, content: String, tags: [[String]]) -> MarketListing? {
        MarketListing(id: "id1", pubkey: "pk1", kind: kind, content: content,
                      createdAt: Date(timeIntervalSince1970: 1_790_000_000), tags: tags)
    }

    /// zap.cooking writes 30018 with NIP-99-style tags and plain-text content.
    func testTagShapedProduct() throws {
        let l = try XCTUnwrap(listing(kind: 30018, content: "reverse osmosis", tags: [
            ["d", "fe8beb74-d1ad-414d-bcbc-e980b4784e96"], ["title", "Water"],
            ["summary", "Bottle of Water"], ["price", "1000", "SAT"], ["t", "ingredients"],
            ["status", "active"], ["image", "https://i.nostr.build/leUHRTQsC4lZHPkp.jpg"],
            ["location", "USA"],
        ]))
        XCTAssertEqual(l.title, "Water")
        XCTAssertEqual(l.summary, "Bottle of Water")
        XCTAssertEqual(l.priceLabel, "1,000 sats")
        XCTAssertEqual(l.location, "USA")
        XCTAssertEqual(l.dTag, "fe8beb74-d1ad-414d-bcbc-e980b4784e96")
        XCTAssertEqual(l.coverImage?.absoluteString, "https://i.nostr.build/leUHRTQsC4lZHPkp.jpg")
        XCTAssertFalse(l.isAuction)
    }

    /// Classic NIP-15: everything in JSON content, price as a JSON number.
    func testJSONProduct() throws {
        let content = #"{"id":"christmas-baking-j99b2pic5f","stall_id":"bekka-s-marketplace-o12dcmhx5v","name":"Christmas Baking","description":"A selection of traditional Christmas cookies","images":["https://image.nostr.build/ace27469439db3e4b2c3b003823ab5dd51c51e2e0675568d42cd5055661ae879.jpg"],"price":21000,"quantity":21,"currency":"SATS"}"#
        let l = try XCTUnwrap(listing(kind: 30018, content: content, tags: [
            ["d", "christmas-baking-j99b2pic5f"], ["t", "Baking"],
        ]))
        XCTAssertEqual(l.title, "Christmas Baking")
        XCTAssertEqual(l.summary, "A selection of traditional Christmas cookies")
        XCTAssertEqual(l.price, "21000")
        XCTAssertEqual(l.priceLabel, "21,000 sats")
        XCTAssertEqual(l.images.count, 1)
        XCTAssertEqual(l.plebeianURL?.absoluteString, "https://plebeian.market/products/id1")
    }

    /// Conduit puts JSON into 30402 content, images as objects.
    func testConduitJSONClassified() throws {
        let content = #"{"title":"Mug","summary":"Orange mug","price":2,"currency":"USD","images":[{"url":"https://shop.conduit.market/mug.jpg"}]}"#
        let l = try XCTUnwrap(listing(kind: 30402, content: content, tags: [["d", "mug"]]))
        XCTAssertEqual(l.title, "Mug")
        XCTAssertEqual(l.summary, "Orange mug")
        XCTAssertEqual(l.coverImage?.absoluteString, "https://shop.conduit.market/mug.jpg")
        XCTAssertEqual(l.priceLabel, "2 USD")
    }

    func testFiatPriceAndAuction() throws {
        let classified = try XCTUnwrap(listing(kind: 30402, content: "Long markdown body", tags: [
            ["title", "John Deere 1214 Crimper"], ["image", "https://i.nostr.build/jpyiOroOpPml9vEwJnfVEA.jpg"],
            ["price", "1000", "CAD"],
        ]))
        XCTAssertEqual(classified.priceLabel, "1000 CAD")
        XCTAssertEqual(classified.summary, "Long markdown body")

        let auction = try XCTUnwrap(listing(kind: 30020,
            content: #"{"name":"Rare coin","images":["https://x.example/c.jpg"],"starting_bid":5000}"#, tags: []))
        XCTAssertTrue(auction.isAuction)
        XCTAssertEqual(auction.priceLabel, "5,000 sats")
        XCTAssertEqual(auction.plebeianURL?.absoluteString, "https://plebeian.market/auction/id1")
    }

    func testRejectsWhatCannotBeShownOrBought() {
        let image = ["image", "https://x.example/a.jpg"]
        XCTAssertNil(listing(kind: 30402, content: "", tags: [["title", "No photo"]]), "no image")
        XCTAssertNil(listing(kind: 30402, content: "", tags: [image]), "no title")
        XCTAssertNil(listing(kind: 30402, content: "", tags: [["title", "Untitled Product"], image]))
        XCTAssertNil(listing(kind: 30402, content: "", tags: [["title", "Ouroboros"], image, ["status", "sold"]]))
        XCTAssertNil(listing(kind: 30402, content: "", tags: [["title", "Gone"], image, ["visibility", "hidden"]]))
        XCTAssertNil(listing(kind: 30402, content: "", tags: [["title", "FTP"], ["image", "ftp://x/a.jpg"]]))
        XCTAssertNil(listing(kind: 1, content: "", tags: [["title", "Note"], image]), "not a listing kind")
        XCTAssertNotNil(listing(kind: 30402, content: "", tags: [["title", "Fine"], image, ["status", "active"]]))
    }

    func testMissingPriceShowsQuestionMark() throws {
        let l = try XCTUnwrap(listing(kind: 30402, content: "", tags: [["title", "Ask me"], ["image", "https://x.example/a.jpg"]]))
        XCTAssertEqual(l.priceLabel, "? sats")
    }

    func testCategoryMatchesWholeWordsInText() {
        // MyNostrSpace's substring match put both of these in Art.
        XCTAssertEqual(MarketCategory.classify(topics: [], text: "Start your party right"), .other)
        XCTAssertEqual(MarketCategory.classify(topics: [], text: "Hand-pulled screen print"), .art)
        XCTAssertEqual(MarketCategory.classify(topics: [], text: "A new hardware wallet"), .bitcoin)
        XCTAssertEqual(MarketCategory.classify(topics: [], text: "Running shoes, size 10"), .shoes)
        XCTAssertEqual(MarketCategory.classify(topics: [], text: "Cotton hoodie"), .clothing)
    }

    func testCategoryMatchesTopicSubstrings() {
        XCTAssertEqual(MarketCategory.classify(topics: ["Bitcoin-Hardware"], text: ""), .bitcoin)
        XCTAssertEqual(MarketCategory.classify(topics: ["coffee-beans"], text: ""), .foodAndDrink)
        XCTAssertEqual(MarketCategory.classify(topics: ["misc"], text: ""), .other)
    }
}
