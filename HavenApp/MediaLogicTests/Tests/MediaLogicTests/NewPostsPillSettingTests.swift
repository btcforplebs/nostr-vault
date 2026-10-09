import XCTest
@testable import MediaLogic

final class NewPostsPillSettingTests: XCTestCase {
    /// A config saved before the setting existed keeps the pill on.
    func testMissingKeyDefaultsToShown() throws {
        let saved = try JSONEncoder().encode(HavenConfig())
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNotNil(dict["showNewPostsPill"], "the setting is not saved at all")
        dict.removeValue(forKey: "showNewPostsPill")
        let old = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertTrue(try JSONDecoder().decode(HavenConfig.self, from: old).showNewPostsPill)
    }

    func testOffSurvivesSaveAndLoad() throws {
        var config = HavenConfig()
        config.showNewPostsPill = false
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(try JSONDecoder().decode(HavenConfig.self, from: data).showNewPostsPill)
    }
}
