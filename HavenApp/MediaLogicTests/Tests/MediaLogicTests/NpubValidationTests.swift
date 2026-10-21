import XCTest
@testable import MediaLogic

/// The two malformed strings here are not invented: they are the entries that
/// shipped in starter_packs.json, and each breaks the lenient decoder in a
/// different way.
final class NpubValidationTests: XCTestCase {

    /// jack, from the shipped starter packs. Known-good, so a test run that
    /// rejects everything cannot look like a pass.
    private let goodNpub = "npub1sg6plzptd64u62a878hep2kev88swjh3tw00gjsfl8f237lmu63q0uf63m"
    private let goodHex = "82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2"

    func testAcceptsAWellFormedNpub() {
        XCTAssertEqual(NpubValidation.hexPubkey(fromNpub: goodNpub), goodHex)
    }

    func testAcceptsUppercaseAndSurroundingWhitespace() {
        XCTAssertEqual(NpubValidation.hexPubkey(fromNpub: "  \(goodNpub.uppercased())  "), goodHex)
    }

    func testRejectsMixedCase() {
        var mixed = Array(goodNpub)
        mixed[6] = Character(String(mixed[6]).uppercased())
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: String(mixed)))
    }

    /// The MartyBent entry. It is 63 characters and decodes to 32 bytes, so
    /// length tells you nothing — only the checksum does. Without this the app
    /// publishes a p-tag for a pubkey nobody chose.
    func testRejectsAnNpubThatDecodesToThirtyTwoPlausibleBytes() {
        let typo = "npub1s33sw46p7vpsmak6v8j4x2naxqvqgv5xpep0lmllz9lxm7qds8gs8r5n32"
        XCTAssertEqual(typo.count, 63)
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: typo))
    }

    /// The Snowden entry. It contains a later "1", and a decoder that splits on
    /// the *last* separator reads the human-readable part as
    /// "npub1wjwj5r9ytyhgg7nwmy75t8pqzn7xapg5c5k0q8q9qqk9f" and returns three
    /// bytes, which then go into a p-tag as-is.
    func testRejectsAnNpubWhoseLastSeparatorIsNotTheRealOne() {
        let strayOne = "npub1wjwj5r9ytyhgg7nwmy75t8pqzn7xapg5c5k0q8q9qqk9f1vvv4qsvvxs2w"
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: strayOne))
    }

    func testRejectsAWrongHumanReadablePart() {
        // A valid nsec must not be usable anywhere an npub is expected.
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"))
    }

    func testRejectsAnEmptyOrSeparatorlessString() {
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: ""))
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: "npub"))
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: "npub1"))
    }

    func testRejectsACharacterOutsideTheBech32Alphabet() {
        // "b" is excluded from the alphabet precisely to avoid this confusion.
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: goodNpub.replacingOccurrences(of: "s", with: "b")))
    }

    func testRejectsAPayloadThatIsNotThirtyTwoBytes() {
        // Truncating drops real data, so this fails the checksum too; the point
        // is that nothing shorter can slip through as a pubkey.
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: String(goodNpub.dropLast(10))))
    }

    func testValidNpubsKeepsOrderAndDropsBadOnesAndDuplicates() {
        let second = "npub1cn4t4cd78nm900qc2hhqte5aa8c9njm6qkfzw95tszufwcwtcnsq7g3vle"
        let input = [
            goodNpub,
            "npub1s33sw46p7vpsmak6v8j4x2naxqvqgv5xpep0lmllz9lxm7qds8gs8r5n32",
            second,
            goodNpub.uppercased(),
        ]
        XCTAssertEqual(NpubValidation.validNpubs(input), [goodNpub, second])
    }

    // MARK: - nsec (key import)

    /// The NIP-19 example key.
    private let goodNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let goodSecretHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

    func testAcceptsAWellFormedNsec() {
        XCTAssertEqual(NpubValidation.hexSecretKey(fromNsec: " \(goodNsec)\n"), goodSecretHex)
    }

    /// One mistyped character still decodes to 32 bytes under the lenient
    /// decoder; importing it would replace the stored key with a stranger's.
    func testRejectsANsecWithOneMistypedCharacter() {
        var typo = Array(goodNsec)
        typo[10] = "q"
        XCTAssertNotEqual(String(typo), goodNsec)
        XCTAssertNil(NpubValidation.hexSecretKey(fromNsec: String(typo)))
    }

    /// Correct checksum, 31-byte payload.
    func testRejectsANsecThatIsNotThirtyTwoBytes() {
        XCTAssertNil(NpubValidation.hexSecretKey(fromNsec: "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9u7jpluy"))
    }

    /// Same bytes, other prefix: a pasted npub is not a secret key, and an
    /// nsec is not a pubkey.
    func testRejectsTheWrongPrefixEitherWay() {
        let npubOfSameBytes = "npub1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqu95glp"
        XCTAssertNil(NpubValidation.hexSecretKey(fromNsec: npubOfSameBytes))
        XCTAssertNil(NpubValidation.hexPubkey(fromNpub: goodNsec))
        XCTAssertEqual(NpubValidation.hexPubkey(fromNpub: npubOfSameBytes), goodSecretHex)
    }
}
