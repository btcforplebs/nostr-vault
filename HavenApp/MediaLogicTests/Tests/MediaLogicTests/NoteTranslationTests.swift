import XCTest
@testable import MediaLogic

final class NoteTranslationTests: XCTestCase {
    func testTargetFollowsDeviceWhenUnset() {
        XCTAssertEqual(NoteTranslation.targetCode(setting: "", preferredLanguages: ["de-DE", "en-US"]), "de")
        XCTAssertEqual(NoteTranslation.targetCode(setting: "", preferredLanguages: []), "en")
    }

    func testChosenTargetWins() {
        XCTAssertEqual(NoteTranslation.targetCode(setting: "ja", preferredLanguages: ["en-US"]), "ja")
    }

    func testOfferOnlyForKnownOtherLanguage() {
        XCTAssertTrue(NoteTranslation.shouldOffer(detected: "de", target: "en"))
        XCTAssertFalse(NoteTranslation.shouldOffer(detected: "en", target: "en"))
        XCTAssertFalse(NoteTranslation.shouldOffer(detected: nil, target: "en"))
    }

    func testLinksAndReferencesStayOut() {
        let text = "Guten Morgen #nostr https://example.com/x.jpg\nnostr:note1abc @alice schöner Tag"
        XCTAssertEqual(NoteTranslation.translatableText(text), "Guten Morgen #nostr\n@alice schöner Tag")
    }

    func testSettingsSurviveSaveAndOldConfigs() throws {
        var config = HavenConfig()
        config.showTranslateButton = false
        config.translateTargetLanguage = "es"
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(HavenConfig.self, from: data)
        XCTAssertFalse(back.showTranslateButton)
        XCTAssertEqual(back.translateTargetLanguage, "es")

        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "showTranslateButton")
        dict.removeValue(forKey: "translateTargetLanguage")
        let old = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertTrue(old.showTranslateButton)
        XCTAssertEqual(old.translateTargetLanguage, "")
    }
}
