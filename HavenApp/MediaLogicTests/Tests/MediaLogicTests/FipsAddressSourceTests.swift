import XCTest
@testable import MediaLogic

/// The "owner" address source is gone (Tron S3, Desktop Vaults P8): the
/// account npub is never a mesh address, and a saved "owner" reads as
/// "detected".
final class FipsAddressSourceTests: XCTestCase {
    private let owner = "npub1" + String(repeating: "o", count: 58)
    private let detected = "npub1" + String(repeating: "d", count: 58)

    private func decoded(_ source: String?) throws -> HavenConfig {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig())) as! [String: Any]
        json["fipsAddressSource"] = source
        return try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testASavedOwnerReadsAsDetected() throws {
        XCTAssertEqual(try decoded("owner").fipsAddressSource, "detected")
        XCTAssertEqual(try decoded("custom").fipsAddressSource, "custom")
        XCTAssertEqual(try decoded("detected").fipsAddressSource, "detected")
        XCTAssertEqual(try decoded(nil).fipsAddressSource, "detected")
        XCTAssertEqual(try decoded("something newer").fipsAddressSource, "detected")
    }

    func testTheAccountNpubIsNeverTheMeshAddress() {
        var config = HavenConfig()
        config.ownerNpub = owner
        config.fipsPublishEnabled = true
        // Even set in memory, "owner" never lists the account npub.
        config.fipsAddressSource = "owner"
        XCTAssertNil(config.fipsBlossomURL(detectedNpub: nil))
        XCTAssertEqual(config.fipsBlossomURL(detectedNpub: detected), "http://\(detected).fips:\(config.relayPort)")
        config.fipsAddressSource = "detected"
        XCTAssertNil(config.fipsBlossomURL(detectedNpub: nil), "nothing detected: nothing listed")
    }
}
