import XCTest
@testable import MediaLogic

/// The phone's "is this photo on the vault yet?" HEAD carries this phone's
/// mesh-key "get", never the account's: the mesh door (haven-go mesh_safety.go) answers 404 to an
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
