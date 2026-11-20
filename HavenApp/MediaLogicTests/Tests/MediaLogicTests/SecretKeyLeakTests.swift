import XCTest
import CryptoKit
@testable import MediaLogic

/// The key-leak guard (Logen 2026-11-20). Every key here is 32 random bytes
/// made by the test run itself, never a real one.
final class SecretKeyLeakTests: XCTestCase {
    private func throwawaySecret() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    }

    private func nsec(_ secret: Data) -> String {
        Bech32.encode(hrp: "nsec", data: secret)!
    }

    /// Stands in for secp256k1 (the Go core, not linked here): a fixed map
    /// from the secret, so the test can tell which bytes were handed over.
    private func fakeDerive(_ secret: Data) -> String? {
        SHA256.hash(data: secret).map { String(format: "%02x", $0) }.joined()
    }

    override func tearDown() {
        PublicKeyRegistry.shared.reset()
        super.tearDown()
    }

    // MARK: - Detection

    func testFindsAWorkingKeyAnywhereInText() {
        let key = nsec(throwawaySecret())
        XCTAssertEqual(key.count, 63)
        XCTAssertTrue(SecretKeyLeak.containsSecretKey(key))
        XCTAssertTrue(SecretKeyLeak.containsSecretKey("my name is \(key) hi"))
        XCTAssertTrue(SecretKeyLeak.containsSecretKey("{\"name\":\"\(key)\"}"), "a kind 0's JSON content")
    }

    func testNostrURIForm() {
        XCTAssertTrue(SecretKeyLeak.containsSecretKey("nostr:\(nsec(throwawaySecret()))"))
    }

    func testUppercaseIsValidMixedCaseIsNot() {
        let key = nsec(throwawaySecret())
        XCTAssertTrue(SecretKeyLeak.containsSecretKey(key.uppercased()))
        let mixed = String(key.prefix(10)).uppercased() + key.dropFirst(10)
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(mixed))
    }

    func testBadChecksumIsIgnored() {
        var chars = Array(nsec(throwawaySecret()))
        let last = chars.count - 1
        chars[last] = chars[last] == "q" ? "p" : "q"
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(String(chars)))
    }

    func testTruncatedAndPrefixOnlyAreIgnored() {
        let key = nsec(throwawaySecret())
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(String(key.prefix(50))), "the 50-character farm")
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(String(key.dropLast())))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey("nsec1"))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey("paste your nsec1... here"))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey("an insecure Fonseca"))
    }

    func testOtherHrpsAreIgnored() {
        let secret = throwawaySecret()
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(Bech32.encode(hrp: "npub", data: secret)!))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(Bech32.encode(hrp: "note", data: secret)!))
    }

    func testWrongLengthPayloadIsIgnored() {
        // 31 bytes and 33 bytes don't make 58 data characters with zero padding.
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(Bech32.encode(hrp: "nsec", data: Data(repeating: 7, count: 31))!))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(Bech32.encode(hrp: "nsec", data: Data(repeating: 7, count: 33))!))
    }

    func testTagsAreChecked() {
        let key = nsec(throwawaySecret())
        XCTAssertTrue(SecretKeyLeak.containsSecretKey(content: "hello", tags: [["t", "x"], ["alt", key]]))
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(content: "hello", tags: [["t", "x"]]))
    }

    func testBlockedErrorCarriesTheMessage() {
        XCTAssertEqual(SecretKeyLeak.Blocked().localizedDescription,
                       "This is a secret key. Publishing it lets anyone post as you.")
    }

    // MARK: - Derivation

    func testDerivesEachKeysPubkeyOnce() {
        let a = throwawaySecret(), b = throwawaySecret()
        var handed: [Data] = []
        let text = "\(nsec(a)) and again \(nsec(a)) and \(nsec(b).uppercased())"
        let pubs = SecretKeyLeak.derivedPubkeys(in: text) { secret in
            handed.append(secret)
            return self.fakeDerive(secret)
        }
        XCTAssertEqual(pubs, [fakeDerive(a)!, fakeDerive(b)!])
        XCTAssertEqual(handed.first, a, "the decoded bytes are the generated secret")
        XCTAssertTrue(handed.contains(b))
    }

    func testProfileTextCoversEveryField() {
        let key = nsec(throwawaySecret())
        var p = FeedProfile(pubkey: String(repeating: "1", count: 64))
        p.lud16 = key
        XCTAssertTrue(SecretKeyLeak.containsSecretKey(SecretKeyLeak.profileText(p)))
        p.lud16 = nil
        p.website = "https://example.com/\(key)"
        XCTAssertTrue(SecretKeyLeak.containsSecretKey(SecretKeyLeak.profileText(p)))
    }

    // MARK: - Registry + gate

    func testMarkedKeyIsOutsideEvenInYourWeb() {
        let secret = throwawaySecret()
        let exposed = fakeDerive(secret)!
        let me = String(repeating: "a", count: 64)
        let web = WebGate.Web(own: [me], whitelist: [exposed], web: [exposed], hop3: [])
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web), .inside)

        let pubs = SecretKeyLeak.derivedPubkeys(in: "name: \(nsec(secret))", derive: fakeDerive)
        XCTAssertTrue(PublicKeyRegistry.shared.mark(pubs))
        XCTAssertFalse(PublicKeyRegistry.shared.mark(pubs), "already marked")
        XCTAssertTrue(PublicKeyRegistry.shared.isPublic(exposed.uppercased()))

        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web), .outside)
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web, reach: .webAndHop3), .outside)
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web, reach: .everyone), .inside,
                       "Everyone shows strangers, so it shows this one too")
        let blocked = WebGate.Web(own: [me], web: [exposed], blocked: [exposed])
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: blocked), .blocked, "a block still wins")
        XCTAssertEqual(WebGate.judge(.init(signer: me), in: web), .inside)
    }
}
