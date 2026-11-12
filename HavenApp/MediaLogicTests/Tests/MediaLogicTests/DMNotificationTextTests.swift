import XCTest
@testable import MediaLogic

/// DM notifications hide the message text by default (Logen, 2026-11-12):
/// sender only. Someone who never touched the setting gets the new default;
/// a saved choice is kept.
final class DMNotificationTextTests: XCTestCase {
    func testHiddenByDefault() {
        XCTAssertFalse(HavenConfig.default.showDMTextInNotifications)
        XCTAssertEqual(NotificationPolicy.dmNotificationText("meet at 6", showsText: false), "")
    }

    func testShownWhenTurnedOn() {
        XCTAssertEqual(NotificationPolicy.dmNotificationText("meet  at\n6", showsText: true), "meet at 6")
    }

    func testConfigSavedBeforeTheSettingHidesText() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "showDMTextInNotifications"), "the key is saved")
        let old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertFalse(try JSONDecoder().decode(HavenConfig.self, from: old).showDMTextInNotifications)
    }

    func testSavedChoiceIsKept() throws {
        var config = HavenConfig.default
        config.showDMTextInNotifications = true
        let loaded = try JSONDecoder().decode(HavenConfig.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(loaded.showDMTextInNotifications)
    }

    /// The one place DM text reaches a notification goes through the setting.
    func testTheDMAlertReadsTheSetting() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("HavenApp")
        let text = try String(contentsOf: app.appendingPathComponent("Services/LocalNotificationService.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("showsText: ConfigService.shared.config.showDMTextInNotifications"))
        XCTAssertFalse(text.contains("NotificationPolicy.dmPreview("), "no DM text path around the setting")
    }
}
