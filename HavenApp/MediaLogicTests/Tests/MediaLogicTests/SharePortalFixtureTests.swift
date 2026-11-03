import XCTest
@testable import MediaLogic

/// The share portal's shared contract (docs/SHARE_PORTAL_CONTRACT.md). The
/// fixtures are read by Android's shareportal tests too, so both platforms
/// classify and validate the same inputs the same way.
final class SharePortalFixtureTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SharePortal"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testClassifierFixtures() throws {
        let cases = try XCTUnwrap(fixture("classifier-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 30)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let i = c["input"] as? [String: Any] ?? [:]
            let files = (i["files"] as? [[String: String]] ?? []).map {
                NVShareInput.FileInfo(mime: $0["mime"] ?? "", name: $0["name"] ?? "")
            }
            let input = NVShareInput(url: i["url"] as? String, title: i["title"] as? String, text: i["text"] as? String,
                                     selection: i["selection"] as? String, files: files,
                                     ldTypes: i["ld_types"] as? [String] ?? [])
            let expect = try XCTUnwrap(c["expect"] as? [String], name)
            XCTAssertEqual(NVShareClassifier.classify(input).map(\.rawValue), expect, name)
        }
    }

    func testValidEnvelopesDecodeAndRoundTrip() throws {
        let valid = try XCTUnwrap(fixture("envelope-cases")["valid"] as? [[String: Any]])
        XCTAssertFalse(valid.isEmpty)
        for c in valid {
            let name = c["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["json"]))
            let intent = try XCTUnwrap(NVShareIntent.decode(data), name)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            XCTAssertEqual(intent.action.rawValue, expect["action"] as? String, name)
            XCTAssertEqual(intent.files.count, expect["files"] as? Int, name)
            XCTAssertEqual(intent.form.keys.sorted(), expect["form_keys"] as? [String], name)
            XCTAssertEqual(intent.source.url, expect["url"] as? String, name)
            XCTAssertEqual(NVShareIntent.decode(intent.encoded()), intent, "\(name) round trip")
        }
    }

    func testInvalidEnvelopesAreRejected() throws {
        let invalid = try XCTUnwrap(fixture("envelope-cases")["invalid"] as? [[String: Any]])
        XCTAssertGreaterThan(invalid.count, 15)
        for c in invalid {
            let name = c["name"] as? String ?? "?"
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["json"]))
            XCTAssertNil(NVShareIntent.decode(data), name)
        }
    }

    /// Positive control for the invalid list: the base each invalid case was
    /// made from does decode, so a rejection is about the one broken field.
    func testInvalidCasesDifferFromAValidBase() throws {
        let valid = try XCTUnwrap(fixture("envelope-cases")["valid"] as? [[String: Any]])
        let base = try XCTUnwrap(valid.first?["json"])
        XCTAssertNotNil(NVShareIntent.decode(try JSONSerialization.data(withJSONObject: base)))
    }
}
