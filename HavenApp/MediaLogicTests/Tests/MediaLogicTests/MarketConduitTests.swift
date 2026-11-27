import XCTest
@testable import MediaLogic

/// Conduit listings (client tag "Conduit Merchant Portal") buy on Conduit by
/// coordinate; every other listing keeps Plebeian. Shapes from the live capture
/// in RESEARCH/NV_CONDUIT_BUY_LINK_2026_11_26.md.
final class MarketConduitTests: XCTestCase {
    private let handler = "31990:" + String(repeating: "f", count: 64) + ":conduit-merchant"
    private let seller = String(repeating: "5", count: 64)
    private let eventID = String(repeating: "4", count: 64)

    private func listing(kind: Int = 30402, tags: [[String]]) throws -> MarketListing {
        try XCTUnwrap(MarketListing(id: eventID, pubkey: seller, kind: kind, content: "Hoodie",
                                    createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                    tags: [["title", "Genesis XXI Hoodie"], ["image", "https://img/h.jpg"],
                                           ["price", "60", "USD"]] + tags))
    }

    func testClientTagByNameOrHandler() {
        XCTAssertTrue(MarketListing.isConduit(tags: [["client", "Conduit Merchant Portal", handler, "wss://relay.conduit.market"]]))
        XCTAssertTrue(MarketListing.isConduit(tags: [["client", "Conduit Merchant Portal"]]))
        XCTAssertTrue(MarketListing.isConduit(tags: [["client", "Renamed", handler]]))
        XCTAssertFalse(MarketListing.isConduit(tags: [["client", "Shopstr", "31990:" + seller + ":shopstr"]]))
        XCTAssertFalse(MarketListing.isConduit(tags: [["t", "conduit"], ["r", "wss://relay.conduit.market"]]))
    }

    func testConduitListingBuysOnConduitByCoordinate() throws {
        let l = try listing(tags: [["d", "hoodie-2xl"], ["client", "Conduit Merchant Portal", handler]])
        let buy = try XCTUnwrap(l.buyLink)
        XCTAssertEqual(buy.label, "Buy on Conduit")
        XCTAssertEqual(buy.url.absoluteString, "https://shop.conduit.market/products/30402%3A\(seller)%3Ahoodie-2xl")
        XCTAssertEqual(l.messageToSeller, "Hi! I'm interested in “Genesis XXI Hoodie”.\n\(buy.url.absoluteString)")
    }

    func testNoDTagUsesEventIDAndOtherKindsTheSellersShop() throws {
        let noD = try listing(tags: [["client", "Conduit Merchant Portal"]])
        XCTAssertEqual(noD.buyLink?.url.absoluteString, "https://shop.conduit.market/products/\(eventID)")
        let product = try listing(kind: 30018, tags: [["d", "x"], ["client", "Conduit Merchant Portal"]])
        let buy = try XCTUnwrap(product.buyLink)
        XCTAssertEqual(buy.label, "Seller on Conduit")
        XCTAssertTrue(buy.url.absoluteString.hasPrefix("https://shop.conduit.market/npub1"))
        XCTAssertEqual(product.messageToSeller, "Hi! I'm interested in “Genesis XXI Hoodie”.")
    }

    func testOtherListingsKeepPlebeian() throws {
        let l = try listing(tags: [["d", "x"], ["client", "Shopstr"]])
        XCTAssertEqual(l.buyLink, .init(site: "Plebeian", url: URL(string: "https://plebeian.market/products/\(eventID)")!, ownPage: true))
        XCTAssertEqual(l.buyLink?.label, "Buy on Plebeian")
    }
}
