import XCTest
@testable import MediaLogic

/// The globe card's Brainstorm button beside "Open in WoT" (Android parity).
final class TrustCardWebButtonTests: XCTestCase {
    private let pubkey = String(repeating: "ab", count: 32)

    func testPersonOpensOnBrainstorm() throws {
        let button = try XCTUnwrap(TrustCardWebButton.forPerson(pubkey))
        XCTAssertEqual(button.title, "Open in Brainstorm")
        XCTAssertEqual(button.short, "Brainstorm")
        let nprofile = try XCTUnwrap(NostrWebLink.nprofile(pubkey: pubkey))
        XCTAssertEqual(button.url.absoluteString, "https://brainstorm.world/p/\(nprofile)")
    }

    func testNoButtonWithoutAUsableKey() {
        XCTAssertNil(TrustCardWebButton.forPerson(""))
        XCTAssertNil(TrustCardWebButton.forPerson("not-hex"))
        XCTAssertNil(TrustCardWebButton.forPerson(String(repeating: "a", count: 63)))
    }
}
