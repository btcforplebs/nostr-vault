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

    private func follows(_ id: String, _ people: [Int]) -> ListVersion {
        ListVersion(id: id, pubkey: "pk", kind: 3, createdAt: 0,
                    tags: people.map { ["p", String(format: "%064x", $0)] }, content: "")
    }

    /// The Merge Test history: 40, 40 with 5 swapped, then halved to 20, 10, 5.
    /// No single step halves the list, so ListShrinkRule.shrank flagged none
    /// while the banner warned "went from 40 to 5 in steps". The steps the
    /// alarm rule calls a drain are flagged now.
    func testListDrainedInHalvesIsFlagged() {
        let swapped = Array(0..<35) + Array(40..<45)
        let v = [follows("5", Array(0..<5)), follows("10", Array(swapped.prefix(10))), follows("20", Array(swapped.prefix(20))),
                 follows("40b", swapped), follows("40a", Array(0..<40))]
        XCTAssertNotNil(ListWipeAlarmRule.alarm(v, own: [], dismissed: []))
        XCTAssertFalse(zip(v.dropFirst(), v).contains { ListShrinkRule.shrank($0, $1) }, "no single step halves it")
        XCTAssertEqual(ListWipeAlarmRule.flagged(v, own: []), ["5", "10"])
        XCTAssertEqual(ListWipeAlarmRule.flagged(v, own: ["5"]), ["10"], "a version Nostr Vault signed is never flagged")
        XCTAssertEqual(ListWipeAlarmRule.flagged([follows("41", Array(0..<41)), follows("40", Array(0..<40))], own: []), [], "growth isn't a wipe")
    }
}
