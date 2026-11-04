import XCTest
@testable import MediaLogic

/// Your space › My devices, against the fixtures the web reads too.
final class MyDevicesStatusTests: XCTestCase {
    func testFixtures() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "status-cases", withExtension: "json", subdirectory: "Fixtures/MyDevices"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rule = try XCTUnwrap(root["rule"] as? [String: Any])
        XCTAssertEqual(rule["d"] as? String, MyDevicesStatus.advertD)
        XCTAssertEqual(rule["skew"] as? Int, MyDevicesStatus.skew)
        XCTAssertEqual(rule["fallback_ttl"] as? Int, MyDevicesStatus.fallbackTTL)
        let now = try XCTUnwrap(root["now"] as? Int)
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 10)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let adverts = (c["adverts"] as? [[String: Any]] ?? []).map {
                MyDevicesStatus.Advert(createdAt: $0["created_at"] as? Int ?? 0, tags: $0["tags"] as? [[String]] ?? [])
            }
            let got = MyDevicesStatus.status(adverts: adverts, now: now, connected: c["connected"] as? Bool ?? false,
                                             checked: c["checked"] as? Bool ?? false)
            let e = try XCTUnwrap(c["expect"] as? [String: Any], name)
            XCTAssertEqual(got.state.rawValue, e["state"] as? String, name)
            XCTAssertEqual(got.lastSeen, e["last_seen"] as? Int, name)
        }
    }

    func testLines() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MyDevicesStatus.line(.init(state: .connected, lastSeen: 1_000_000), now: now), "Connected now")
        XCTAssertEqual(MyDevicesStatus.line(.init(state: .online, lastSeen: 1_000_000 - 720), now: now), "On the mesh · seen 12 min ago")
        XCTAssertEqual(MyDevicesStatus.line(.init(state: .offline, lastSeen: 1_000_000 - 3 * 86_400), now: now), "Offline · last on the mesh 3 d ago")
        XCTAssertEqual(MyDevicesStatus.line(.init(state: .unknown, lastSeen: nil), now: now), "Not seen on the mesh lately")
    }
}
