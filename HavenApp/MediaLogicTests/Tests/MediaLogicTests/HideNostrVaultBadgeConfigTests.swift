import XCTest
@testable import MediaLogic

/// Appearance → "Hide Nostr Vault logo on posts" (HavenConfig.hideNostrVaultBadge):
/// off by default, so the logo keeps showing, and a saved choice survives a reload.
final class HideNostrVaultBadgeConfigTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertFalse(HavenConfig.default.hideNostrVaultBadge)
    }

    func testConfigSavedBeforeTheSettingKeepsTheLogo() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "hideNostrVaultBadge"), "the key is saved")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(try JSONDecoder().decode(HavenConfig.self, from: old).hideNostrVaultBadge)
    }

    func testHiddenSurvivesSaveAndLoad() throws {
        var config = HavenConfig.default
        config.hideNostrVaultBadge = true
        let loaded = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(loaded.hideNostrVaultBadge)
    }
}
