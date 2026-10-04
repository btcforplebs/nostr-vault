import XCTest
@testable import MediaLogic

final class ListingDraftTests: XCTestCase {
    private func draft(category: MarketCategory = .art, price: String = "21,000", currency: String = "SATS") -> ListingDraft {
        ListingDraft(title: "  Sunset print ", summary: "A3 giclée", description: "Signed.\n",
                     price: price, currency: currency, category: category, location: "Ohio",
                     imageURLs: [URL(string: "https://blossom.example/a.jpg")!, URL(string: "https://blossom.example/b.jpg")!])
    }

    func testTagsMatchNIP99() {
        let tags = draft().tags(publishedAt: 1_790_000_000, newDTag: { "d1" })
        XCTAssertEqual(tags, [
            ["d", "d1"], ["title", "Sunset print"], ["summary", "A3 giclée"],
            ["published_at", "1790000000"], ["price", "21000", "SATS"], ["location", "Ohio"],
            ["image", "https://blossom.example/a.jpg"], ["image", "https://blossom.example/b.jpg"],
            ["t", "Art"], ["status", "active"],
        ])
        XCTAssertEqual(draft().content(), "Signed.")
    }

    /// A listing we publish reads back through the grid's parser unchanged,
    /// in every category: the t tag alone has to land it in the same place.
    func testEveryCategoryRoundTrips() throws {
        for category in MarketCategory.allCases {
            var d = draft(category: category)
            d.title = "Item"; d.summary = ""; d.description = ""
            let listing = try XCTUnwrap(MarketListing(id: "x", pubkey: "pk", kind: 30402, content: d.content(),
                                                      createdAt: Date(), tags: d.tags(publishedAt: 0)))
            XCTAssertEqual(listing.category, category, "\(category)")
            XCTAssertEqual(listing.title, "Item")
            XCTAssertEqual(listing.images.count, 2)
            XCTAssertEqual(listing.price, "21000")
        }
    }

    func testIncompleteDrafts() {
        XCTAssertTrue(draft().isComplete)
        XCTAssertFalse(draft(price: "").isComplete)
        XCTAssertFalse(draft(price: "free").isComplete)
        XCTAssertFalse(draft(price: "-5").isComplete)
        var noPhoto = draft(); noPhoto.imageURLs = []
        XCTAssertFalse(noPhoto.isComplete)
        var noTitle = draft(); noTitle.title = "  "
        XCTAssertFalse(noTitle.isComplete)
        XCTAssertEqual(draft(price: "45.50", currency: "USD").normalizedPrice, "45.50")
    }

    func testEditKeepsAddress() {
        var d = draft(); d.dTag = "keep-me"
        XCTAssertEqual(d.tags(publishedAt: 0).first, ["d", "keep-me"])
    }
}
