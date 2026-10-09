import XCTest
@testable import MediaLogic

/// Saving Edit Profile must change only the fields the user edited. It used to
/// publish a kind 0 holding just the form's seven fields, wiping banner, lud06,
/// bot and every other key on every relay.
final class ProfileMetadataMergeTests: XCTestCase {
    private let relayContent = #"{"name":"sat","display_name":"Satoshi","about":"hi","banner":"https://b/x.jpg","lud06":"lnurl1abc","bot":false,"website":"https://a.example"}"#
    private let shown: [String: String] = [
        "display_name": "Satoshi", "name": "sat", "about": "hi", "picture": "",
        "nip05": "", "lud16": "", "website": "https://a.example",
    ]

    private func edited(_ changes: [String: String]) -> [String: String] {
        shown.merging(changes) { _, new in new }
    }

    func testUnknownKeysAreKept() throws {
        let out = ProfileMetadataMerge.merge(base: ProfileMetadataMerge.parseContent(relayContent),
                                             initial: shown, edited: edited(["about": "new bio"]))
        XCTAssertEqual(out["banner"] as? String, "https://b/x.jpg")
        XCTAssertEqual(out["lud06"] as? String, "lnurl1abc")
        // A JSON boolean must survive the round trip as a boolean, not 0.
        let json = try XCTUnwrap(ProfileMetadataMerge.encode(out))
        XCTAssertTrue(json.contains(#""bot":false"#), json)
        XCTAssertTrue(json.contains(#""banner":"https://b/x.jpg""#), json)
    }

    func testEditedFieldIsReplacedAndTrimmed() {
        let out = ProfileMetadataMerge.merge(base: ProfileMetadataMerge.parseContent(relayContent), initial: shown,
                                             edited: edited(["about": "  new bio ", "lud16": "me@wallet.example"]))
        XCTAssertEqual(out["about"] as? String, "new bio")
        XCTAssertEqual(out["lud16"] as? String, "me@wallet.example")
        XCTAssertEqual(out["name"] as? String, "sat")
    }

    /// The form shows the banner now: a new upload replaces it, clearing removes it.
    func testBannerEditIsApplied() {
        let base = ProfileMetadataMerge.parseContent(relayContent)
        let shownBanner = shown.merging([ProfileMetadataMerge.banner: "https://b/x.jpg"]) { _, new in new }
        let replaced = ProfileMetadataMerge.merge(base: base, initial: shownBanner,
                                                  edited: shownBanner.merging([ProfileMetadataMerge.banner: "https://b/new.jpg"]) { _, new in new })
        XCTAssertEqual(replaced["banner"] as? String, "https://b/new.jpg")
        let cleared = ProfileMetadataMerge.merge(base: base, initial: shownBanner,
                                                 edited: shownBanner.merging([ProfileMetadataMerge.banner: ""]) { _, new in new })
        XCTAssertNil(cleared["banner"])
    }

    func testClearedFieldIsRemoved() {
        let out = ProfileMetadataMerge.merge(base: ProfileMetadataMerge.parseContent(relayContent),
                                             initial: shown, edited: edited(["website": "  "]))
        XCTAssertNil(out["website"])
        XCTAssertNotNil(out["name"])
    }

    func testUntouchedFieldKeepsTheNewerRelayValue() {
        // The form opened on a stale cache ("hi"); the relays hold a newer bio.
        let base = ProfileMetadataMerge.parseContent(#"{"about":"newer bio","name":"sat"}"#)
        let out = ProfileMetadataMerge.merge(base: base, initial: shown, edited: edited(["name": "satoshi"]))
        XCTAssertEqual(out["about"] as? String, "newer bio")
        XCTAssertEqual(out["name"] as? String, "satoshi")
    }

    func testUnreadableContentStartsEmpty() {
        XCTAssertTrue(ProfileMetadataMerge.parseContent("not json").isEmpty)
        XCTAssertTrue(ProfileMetadataMerge.parseContent("[1,2]").isEmpty)
        XCTAssertTrue(ProfileMetadataMerge.parseContent(nil).isEmpty)
    }

    func testNoneIsConfirmedOnlyWhenEveryRelayAnswered() {
        XCTAssertTrue(ReplaceableLookup<String>(event: nil, asked: 3, answered: 3).confirmedNone)
        XCTAssertFalse(ReplaceableLookup<String>(event: nil, asked: 3, answered: 2).confirmedNone)
        XCTAssertFalse(ReplaceableLookup<String>(event: nil, asked: 0, answered: 0).confirmedNone)
        XCTAssertFalse(ReplaceableLookup<String>(event: "kind0", asked: 3, answered: 3).confirmedNone)
    }
}
