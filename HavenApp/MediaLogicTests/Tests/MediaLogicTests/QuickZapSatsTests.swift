import XCTest
@testable import MediaLogic

/// A one-tap zap never sends 0 sats: a default under 1000 msats floors at 1.
final class QuickZapSatsTests: XCTestCase {
    func testFloorsAtOneSat() {
        XCTAssertEqual(HavenConfig.quickZapSats(msats: 0), 1)
        XCTAssertEqual(HavenConfig.quickZapSats(msats: 999), 1)
        XCTAssertEqual(HavenConfig.quickZapSats(msats: -5000), 1)
    }

    func testWholeSatsPassThrough() {
        XCTAssertEqual(HavenConfig.quickZapSats(msats: 1000), 1)
        XCTAssertEqual(HavenConfig.quickZapSats(msats: 21_000), 21)
        XCTAssertEqual(HavenConfig.quickZapSats(msats: 21_999), 21)
    }

    func testConfigDefault() {
        var config = HavenConfig()
        config.defaultZapAmount = 500
        XCTAssertEqual(config.quickZapSats, 1)
    }
}
