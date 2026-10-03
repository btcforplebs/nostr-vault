import XCTest
@testable import MediaLogic

/// A note's links each get a card that fetches the page; a spam note with
/// hundreds of links must not become hundreds of requests from the phone.
final class LinkCardsTests: XCTestCase {
    func testHundredsOfLinksGetThreeCards() {
        let links = (1...500).map { URL(string: "https://attacker.example/p\($0)")! }
        XCTAssertEqual(LinkCards.shown(links), Array(links.prefix(3)))
    }

    func testFewerLinksThanTheCapAreAllShown() {
        let links = [URL(string: "https://a.com/x")!, URL(string: "https://b.com/y")!]
        XCTAssertEqual(LinkCards.shown(links), links)
    }
}
