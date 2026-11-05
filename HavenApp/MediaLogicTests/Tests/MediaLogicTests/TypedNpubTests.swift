import XCTest
@testable import MediaLogic

/// Add Account and Block take only a real npub, not any text starting "npub".
final class TypedNpubTests: XCTestCase {
    private let goodNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"

    func testAcceptsAWholeNpub() {
        XCTAssertEqual(NpubValidation.typedNpub(goodNpub), goodNpub)
        XCTAssertEqual(NpubValidation.typedNpub("  nostr:\(goodNpub)\n"), goodNpub)
        XCTAssertEqual(NpubValidation.typedNpub(goodNpub.uppercased()), goodNpub)
    }

    func testRejectsACutOffNpub() {
        XCTAssertNil(NpubValidation.typedNpub(String(goodNpub.dropLast(5))))
    }

    func testRejectsJustThePrefix() {
        XCTAssertNil(NpubValidation.typedNpub("npub"))
        XCTAssertNil(NpubValidation.typedNpub("npub1"))
    }

    func testRejectsAnNsec() {
        XCTAssertNil(NpubValidation.typedNpub("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"))
    }
}
