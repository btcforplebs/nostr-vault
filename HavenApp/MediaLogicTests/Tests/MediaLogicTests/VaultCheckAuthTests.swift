import XCTest
@testable import MediaLogic

/// The phone's "is this photo on the vault yet?" HEAD must carry the owner's
/// signed "get": the mesh door (haven-go mesh_safety.go) answers 404 to an
/// unsigned check of a blob no posted note names, and the phone would then
/// send the photo again.
final class VaultCheckAuthTests: XCTestCase {
    private let sha = String(repeating: "ab", count: 32)
    private let base = URL(string: "http://127.0.0.1:41234/tok")!

    func testCheckIsASignedHead() {
        let request = HomeVaultLogic.vaultCheckRequest(sha256: sha, base: base, authBase64: "ZXZlbnQ=")
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:41234/tok/\(sha)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Nostr ZXZlbnQ=")
    }

    func testUnsignedOnlyWhenSigningFailed() {
        let request = HomeVaultLogic.vaultCheckRequest(sha256: sha, base: base, authBase64: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// What khatru's Blossom GET checks before RejectGet: a "t" of "get", an
    /// "x" naming this blob, and an expiration still in the future.
    func testTagsAreWhatTheDoorAccepts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tags = HomeVaultLogic.vaultCheckAuthTags(sha256: sha, now: now)
        XCTAssertTrue(tags.contains(["t", "get"]))
        XCTAssertTrue(tags.contains(["x", sha]))
        let exp = tags.first { $0.first == "expiration" }.flatMap { Int($0[1]) }
        XCTAssertEqual(exp, 1_800_000_000 + Int(HomeVaultLogic.vaultCheckAuthLifetime))
        XCTAssertGreaterThan(HomeVaultLogic.vaultCheckAuthLifetime, 30)
    }

    /// A remote signer would prompt the owner for every photo's check.
    func testOnlyAKeyOnThePhoneSignsTheCheck() {
        XCTAssertTrue(HomeVaultLogic.signsVaultCheck(signingMode: "local"))
        XCTAssertFalse(HomeVaultLogic.signsVaultCheck(signingMode: "nip46"))
    }

    /// Once per blob: a second check of the same blob reuses the auth, a
    /// different blob does not, and one near expiry is signed again.
    func testOneAuthPerBlobWhileItIsGood() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var auths = VaultCheckAuths()
        XCTAssertNil(auths.auth(for: sha, now: now))
        auths.remember("first", for: sha, now: now)
        XCTAssertEqual(auths.auth(for: sha, now: now.addingTimeInterval(30)), "first")
        XCTAssertNil(auths.auth(for: String(repeating: "cd", count: 32), now: now))
        let nearExpiry = now.addingTimeInterval(HomeVaultLogic.vaultCheckAuthLifetime - VaultCheckAuths.renewMargin)
        XCTAssertNil(auths.auth(for: sha, now: nearExpiry))
    }
}
