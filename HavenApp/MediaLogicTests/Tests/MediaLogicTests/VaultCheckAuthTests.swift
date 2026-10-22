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
}
