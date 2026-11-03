import XCTest
@testable import MediaLogic

final class DMSearchTests: XCTestCase {
    func testEmptyOrBlankQueryMatchesNothing() {
        XCTAssertFalse(DMSearch.nameMatches("", names: ["Alice"]))
        XCTAssertFalse(DMSearch.nameMatches("   \n", names: ["Alice"]))
        XCTAssertNil(DMSearch.newestTextMatch("  ", texts: ["anything"]))
    }

    func testNameMatchIsCaseAndAccentBlind() {
        XCTAssertTrue(DMSearch.nameMatches("jose", names: [nil, "José Núñez"]))
        XCTAssertTrue(DMSearch.nameMatches("ALI", names: ["alice"]))
        XCTAssertTrue(DMSearch.nameMatches("plebs.com", names: [nil, nil, "bob@btcforplebs.com"]))
        XCTAssertFalse(DMSearch.nameMatches("carol", names: ["alice", nil, ""]))
    }

    func testTextMatchPicksTheNewestMessage() {
        let texts = ["coffee at 9?", "sure", "the CAFÉ on Main", "see you"]
        XCTAssertEqual(DMSearch.newestTextMatch("cafe", texts: texts), 2)
        XCTAssertEqual(DMSearch.newestTextMatch("co", texts: ["coffee", "cocoa", "tea"]), 1)
        XCTAssertNil(DMSearch.newestTextMatch("zebra", texts: texts))
    }

    func testExcerptShowsTheMatchedWords() {
        let long = String(repeating: "filler ", count: 30) + "the secret word is lighthouse" + String(repeating: " more", count: 30)
        let e = DMSearch.excerpt(long, query: "lighthouse", radius: 20)
        XCTAssertTrue(e.contains("lighthouse"))
        XCTAssertTrue(e.hasPrefix("…"))
        XCTAssertTrue(e.hasSuffix("…"))
        XCTAssertLessThan(e.count, 80)
    }

    func testExcerptOfShortTextHasNoEllipsis() {
        XCTAssertEqual(DMSearch.excerpt("hi\nthere", query: "there"), "hi there")
    }

    func testExcerptWithAccentsKeepsOriginalText() {
        XCTAssertTrue(DMSearch.excerpt("Meet at the Café Ünïcode now", query: "cafe unicode").contains("Café Ünïcode"))
    }
}
