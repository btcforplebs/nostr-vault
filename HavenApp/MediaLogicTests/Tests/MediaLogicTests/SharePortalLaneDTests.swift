import XCTest
@testable import MediaLogic

/// Share Portal lane D (Pay or zap, Send privately): the pure parts, read
/// from the same fixtures as Android's PayShareTargetTest and
/// ShareContactsSnapshotTest.
final class SharePortalLaneDTests: XCTestCase {

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/SharePortal"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func target(_ d: [String: Any]) -> PayShareTarget? {
        guard let token = d["token"] as? String, let kind = PayShareTarget.Kind(rawValue: d["kind"] as? String ?? "")
        else { return nil }
        return PayShareTarget(token: token, kind: kind, recipientNpub: d["npub"] as? String)
    }

    func testPayTargetFixtures() throws {
        let cases = try XCTUnwrap(fixture("pay-target-cases")["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        var found = 0
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let i = c["input"] as? [String: Any] ?? [:]
            let got = PayShareTarget.find(url: i["url"] as? String, text: i["text"] as? String,
                                          selection: i["selection"] as? String)
            let expect = (c["expect"] as? [String: Any]).flatMap(target)
            XCTAssertEqual(got, expect, name)
            if expect != nil { found += 1 }
        }
        // Both outcomes are exercised, so a finder that always says nil (or
        // always finds) cannot pass.
        XCTAssertGreaterThan(found, 5)
        XCTAssertGreaterThan(cases.count - found, 3)
    }

    /// Every fixture input the finder accepts is one the classifier offers
    /// Pay for, so the review card never opens on nothing.
    func testFinderAgreesWithClassifier() throws {
        let cases = try XCTUnwrap(fixture("pay-target-cases")["cases"] as? [[String: Any]])
        for c in cases where c["expect"] is [String: Any] {
            let i = c["input"] as? [String: Any] ?? [:]
            let input = NVShareInput(url: i["url"] as? String, text: i["text"] as? String, selection: i["selection"] as? String)
            XCTAssertEqual(NVShareClassifier.classify(input).first, .pay, c["name"] as? String ?? "?")
        }
    }

    func testZapFixtures() throws {
        let cases = try XCTUnwrap(fixture("pay-target-cases")["zap"] as? [[String: Any]])
        XCTAssertTrue(cases.contains { $0["expect"] as? Bool == true })
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let t = try XCTUnwrap(target(try XCTUnwrap(c["target"] as? [String: Any])), name)
            XCTAssertEqual(PayShareTarget.canZap(t, profileLightningAddress: c["lud16"] as? String),
                           c["expect"] as? Bool, name)
        }
    }

    func testContactsDecodeFixtures() throws {
        let f = try fixture("contacts-cases")
        let cases = try XCTUnwrap(f["decode"] as? [[String: Any]])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let data: Data
            if let raw = c["raw"] as? String { data = Data(raw.utf8) }
            else { data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(c["json"])) }
            let got = NVShareContactsSnapshot.decode(data)
            guard let expect = c["expect"] as? [String: [String]] else {
                XCTAssertNil(got, name); continue
            }
            let snapshot = try XCTUnwrap(got, name)
            XCTAssertEqual(snapshot.recent.mapValues { $0.map(\.npub) }, expect, name)
        }
    }

    func testContactsRecordFixtures() throws {
        let f = try fixture("contacts-cases")
        let account = try XCTUnwrap(f["account"] as? String)
        for c in try XCTUnwrap(f["record"] as? [[String: Any]]) {
            let name = c["name"] as? String ?? "?"
            let start = (c["start"] as? [String] ?? []).map { NVShareContactsSnapshot.Contact(npub: $0, name: "", picture: nil) }
            let snapshot = NVShareContactsSnapshot(recent: [account: start])
            let add = NVShareContactsSnapshot.Contact(npub: c["add"] as? String ?? "", name: "n", picture: nil)
            XCTAssertEqual(snapshot.recording(add, for: account).contacts(for: account).map(\.npub),
                           c["expect"] as? [String], name)
        }
    }

    func testContactsWriteReadAndKeepOnlyListedAccounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = "npub1" + String(repeating: "q", count: 58)
        let b = "npub1" + String(repeating: "p", count: 58)
        let c = NVShareContactsSnapshot.Contact(npub: b, name: "Bee", picture: nil)
        let s = NVShareContactsSnapshot().recording(c, for: a).recording(c, for: b)
        s.write(root: root)
        XCTAssertEqual(NVShareContactsSnapshot.read(root: root), s)
        XCTAssertEqual(s.keeping(accounts: [a]).recent.keys.sorted(), [a])
        XCTAssertTrue(NVShareContactsSnapshot().contacts(for: nil).isEmpty)
    }
}
