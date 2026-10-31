import XCTest
@testable import MediaLogic

/// A delete token names the one server it is sent to and lasts five minutes.
final class BlossomDeleteAuthTests: XCTestCase {
    private let sha = String(repeating: "a", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tag(_ name: String, _ tags: [[String]]) -> [String] {
        tags.filter { $0.first == name }.map { $0[1] }
    }

    func testNamesTheServerItIsSentTo() {
        let tags = BlossomDeleteAuth.tags(sha256: sha, deleteURL: URL(string: "https://Blossom.Primal.net/\(sha)")!, now: now)
        XCTAssertEqual(tag("server", tags), ["blossom.primal.net"])
        XCTAssertEqual(tag("t", tags), ["delete"])
        XCTAssertEqual(tag("x", tags), [sha])
    }

    func testHomeVaultOverTheMeshIsNamedWithoutItsPort() {
        let tags = BlossomDeleteAuth.tags(sha256: sha, deleteURL: URL(string: "http://npub1abc.fips:3355/\(sha)")!, now: now)
        XCTAssertEqual(tag("server", tags), ["npub1abc.fips"])
    }

    func testExpiresInFiveMinutes() {
        let tags = BlossomDeleteAuth.tags(sha256: sha, deleteURL: URL(string: "https://vault.example/\(sha)")!, now: now)
        XCTAssertEqual(tag("expiration", tags), [String(1_800_000_000 + 300)])
    }
}
