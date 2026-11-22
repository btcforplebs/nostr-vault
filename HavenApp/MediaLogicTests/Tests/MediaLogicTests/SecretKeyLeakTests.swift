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

    func testSkipsTheAllZeroPubkey() {
        // The Go core answers 00..00 for the zero key and for n.
        let zero = String(repeating: "0", count: 64)
        let pubs = SecretKeyLeak.derivedPubkeys(in: nsec(throwawaySecret())) { _ in zero }
        XCTAssertEqual(pubs, [])
    }

    func testRepostExemptOnlyForAnotherKeysSignedEvent() {
        let key = nsec(throwawaySecret())
        let me = String(repeating: "a", count: 64), them = String(repeating: "b", count: 64)
        func event(by pubkey: String) -> String {
            let obj: [String: Any] = ["id": String(repeating: "c", count: 64), "pubkey": pubkey,
                                      "created_at": 1, "kind": 1, "tags": [[String]](),
                                      "content": "look \(key)", "sig": String(repeating: "d", count: 128)]
            return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        }
        XCTAssertEqual(SecretKeyLeak.exemptKinds, [6, 16])
        XCTAssertFalse(SecretKeyLeak.blocksPublish(kind: 6, content: event(by: them), tags: [], signer: me))
        XCTAssertFalse(SecretKeyLeak.blocksPublish(kind: 16, content: event(by: them), tags: [], signer: me))
        XCTAssertFalse(SecretKeyLeak.blocksPublish(kind: 6, content: "", tags: [["e", "x"]], signer: me))
        XCTAssertTrue(SecretKeyLeak.blocksPublish(kind: 6, content: event(by: me), tags: [], signer: me),
                      "a repost of your own note is yours")
        XCTAssertTrue(SecretKeyLeak.blocksPublish(kind: 6, content: "free text \(key)", tags: [], signer: me))
        XCTAssertTrue(SecretKeyLeak.blocksPublish(kind: 6, content: event(by: them), tags: [], signer: ""),
                      "unknown signer is never exempt")
        XCTAssertTrue(SecretKeyLeak.blocksPublish(kind: 6, content: event(by: them), tags: [["alt", key]], signer: me),
                      "tags are always checked")
        XCTAssertTrue(SecretKeyLeak.blocksPublish(kind: 1, content: event(by: them), tags: [], signer: me))
    }

    // MARK: - Edit Profile strip

    func testHiddenFieldHoldingAKeyIsLeftOutAndNamed() {
        let key = nsec(throwawaySecret())
        let merged: [String: Any] = ["name": "Sam", "displayName": key, "bot": false,
                                     "extra": ["nested": "nostr:\(key)"]]
        let tags = [["i", "github:sam", "proof"], ["alt", key]]
        let out = ProfileSecretKeyStrip.strip(merged, tags: tags)
        XCTAssertEqual(out.fields["name"] as? String, "Sam")
        XCTAssertEqual(out.fields["bot"] as? Bool, false)
        XCTAssertNil(out.fields["displayName"])
        XCTAssertNil(out.fields["extra"], "a nested value counts too")
        XCTAssertEqual(out.tags, [["i", "github:sam", "proof"]])
        XCTAssertEqual(out.removed, ["displayName", "extra", "alt tag"])
        let message = out.message ?? ""
        XCTAssertEqual(message, "Removed a secret key from displayName, extra, alt tag.")
        XCTAssertFalse(message.contains("nsec"), "never the key")
        let json = ProfileMetadataMerge.encode(out.fields) ?? ""
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(content: json, tags: out.tags))
    }

    func testFieldWhoseNameIsAKeyIsLeftOutWithoutShowingIt() {
        let key = nsec(throwawaySecret())
        let out = ProfileSecretKeyStrip.strip(["name": "Sam", key: "x"], tags: [[key, "y"]])
        XCTAssertEqual(out.fields.count, 1)
        XCTAssertEqual(out.tags, [])
        XCTAssertEqual(out.message, "Removed a secret key from a field name, a tag.")
        XCTAssertFalse(SecretKeyLeak.containsSecretKey(ProfileMetadataMerge.encode(out.fields) ?? key))
    }

    func testCleanProfileIsUntouched() {
        let merged: [String: Any] = ["name": "Sam", "lud06": "lnurl1xyz", "about": "nsec1 is a prefix"]
        let out = ProfileSecretKeyStrip.strip(merged, tags: [["t", "x"]])
        XCTAssertEqual(out.fields.count, 3)
        XCTAssertEqual(out.tags, [["t", "x"]])
        XCTAssertNil(out.message)
    }

    // MARK: - Registry + gate

    func testMarkedKeyIsOutsideEvenInYourWeb() {
        let secret = throwawaySecret()
        let exposed = fakeDerive(secret)!
        let me = String(repeating: "a", count: 64)
        let web = WebGate.Web(own: [me], whitelist: [exposed], web: [exposed], loose: [])
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web), .inside)

        let pubs = SecretKeyLeak.derivedPubkeys(in: "name: \(nsec(secret))", derive: fakeDerive)
        XCTAssertTrue(PublicKeyRegistry.shared.mark(pubs))
        XCTAssertFalse(PublicKeyRegistry.shared.mark(pubs), "already marked")
        XCTAssertTrue(PublicKeyRegistry.shared.isPublic(exposed.uppercased()))

        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web), .outside)
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web, reach: .webAndLoose), .outside)
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: web, reach: .everyone), .inside,
                       "Everyone shows strangers, so it shows this one too")
        let blocked = WebGate.Web(own: [me], web: [exposed], blocked: [exposed])
        XCTAssertEqual(WebGate.judge(.init(signer: exposed), in: blocked), .blocked, "a block still wins")
        XCTAssertEqual(WebGate.judge(.init(signer: me), in: web), .inside)
    }
}
