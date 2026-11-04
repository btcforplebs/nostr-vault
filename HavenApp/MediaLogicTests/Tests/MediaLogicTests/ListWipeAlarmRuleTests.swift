import XCTest
@testable import MediaLogic

/// docs/LIST_WIPE_ALARM.md, against the fixtures Android and the web app
/// read too.
final class ListWipeAlarmRuleTests: XCTestCase {
    func testFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "alarm-cases", withExtension: "json", subdirectory: "Fixtures/ListAlarm"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rule = try XCTUnwrap(root["rule"] as? [String: Int])
        XCTAssertEqual(rule["lookback"], ListWipeAlarmRule.lookback)
        XCTAssertEqual(rule["alarm_min_items"], ListWipeAlarmRule.minItems)
        XCTAssertEqual(rule["min_items"], ListShrinkRule.minItems)
        XCTAssertEqual(rule["min_content"], ListShrinkRule.minContent)
        XCTAssertEqual(rule["history"], ListWipeAlarmRule.history)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 20)
        var alarms = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let versions = (c["versions"] as? [[String: Any]] ?? []).map { v in
                ListVersion(id: v["id"] as? String ?? "", pubkey: "pk", kind: v["kind"] as? Int ?? 0,
                            createdAt: Int64(v["created_at"] as? Int ?? 0), tags: v["tags"] as? [[String]] ?? [],
                            content: v["content"] as? String ?? "")
            }
            let got = ListWipeAlarmRule.alarm(versions, own: Set(c["own"] as? [String] ?? []),
                                              dismissed: Set(c["dismissed"] as? [String] ?? []))
            guard let e = c["expect"] as? [String: Any] else {
                XCTAssertNil(got, name)
                continue
            }
            alarms += 1
            let a = try XCTUnwrap(got, name)
            XCTAssertEqual(a.before.id, e["before"] as? String, name)
            XCTAssertEqual(a.after.id, e["after"] as? String, name)
            XCTAssertEqual(a.how.rawValue, e["how"] as? String, name)
            XCTAssertEqual(a.from, e["from"] as? Int, name)
            XCTAssertEqual(a.to, e["to"] as? Int, name)
            XCTAssertEqual(a.lost, e["lost"] as? Int, name)
            XCTAssertEqual(a.client, e["client"] as? String, name)
            XCTAssertEqual(a.claimsNostrVault, e["claims_nostr_vault"] as? Bool, name)
        }
        XCTAssertGreaterThan(alarms, 8, "positive control: the fixtures do raise alarms")
    }
}
