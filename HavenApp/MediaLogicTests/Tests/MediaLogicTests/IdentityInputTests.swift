import XCTest
@testable import MediaLogic

/// The "I use Nostr" field: what's pasted decides read-only vs can-post.
final class IdentityInputTests: XCTestCase {
    private let hex = String(repeating: "a", count: 64)

    func testPublicKeysAreReadOnly() {
        for raw in ["npub1abc", "  NPUB1ABC\n", "nostr:npub1abc", "nprofile1qqs"] {
            let input = IdentityInput(raw)
            guard case .publicKey = input else { return XCTFail("\(raw) → \(input)") }
            XCTAssertFalse(input.canPost)
            XCTAssertEqual(input.setupMode, "browse")
        }
    }

    func testNIP05IsReadOnly() {
        XCTAssertEqual(IdentityInput("Alice@Example.com"), .nip05("alice@example.com"))
        XCTAssertEqual(IdentityInput("example.com"), .nip05("example.com"))
        XCTAssertEqual(IdentityInput("_@example.com").setupMode, "browse")
    }

    func testKeysAndSignersCanPost() {
        XCTAssertEqual(IdentityInput("nsec1xyz"), .secretKey("nsec1xyz"))
        XCTAssertEqual(IdentityInput("nostr:NSEC1XYZ"), .secretKey("nsec1xyz"))
        XCTAssertEqual(IdentityInput("ncryptsec1qq"), .encryptedSecretKey("ncryptsec1qq"))
        let bunker = IdentityInput("bunker://\(hex)?relay=wss://relay.example.com")
        guard case .remoteSigner(let info) = bunker else { return XCTFail("\(bunker)") }
        XCTAssertEqual(info.signerPubkey, hex)
        for input in [IdentityInput("nsec1xyz"), IdentityInput("ncryptsec1qq"), bunker] {
            XCTAssertTrue(input.canPost)
            XCTAssertEqual(input.setupMode, "full")
        }
    }

    /// A raw hex key could be either kind; guessing "public" would put
    /// someone's private key on screen as their identity.
    func testRawHexIsRefused() {
        XCTAssertEqual(IdentityInput(hex), .hexKey)
        XCTAssertEqual(IdentityInput(hex.uppercased()), .hexKey)
        XCTAssertNil(IdentityInput(hex).setupMode)
        XCTAssertFalse(IdentityInput(hex).canPost)
    }

    func testJunkIsNotUsable() {
        for raw in ["", "   ", "hello", "@example.com", "alice@", "alice@example", "a b.com",
                    "https://example.com", "bunker://notakey", ".com", "example."] {
            XCTAssertNil(IdentityInput(raw).setupMode, raw)
        }
        XCTAssertEqual(IdentityInput(""), .empty)
        XCTAssertNil(IdentityInput("").hint)
        XCTAssertNotNil(IdentityInput("hello").hint)
    }
}
