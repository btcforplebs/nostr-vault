import XCTest
@testable import MediaLogic

final class BackgroundModePolicyTests: XCTestCase {
    func testWindowServicesRunOnlyWithTheWindowInBackgroundMode() {
        XCTAssertFalse(BackgroundModePolicy.runsWindowServices(isOn: true, windowOpen: false))
        XCTAssertTrue(BackgroundModePolicy.runsWindowServices(isOn: true, windowOpen: true))
    }

    func testModeOffKeepsTodaysBehaviour() {
        XCTAssertTrue(BackgroundModePolicy.runsWindowServices(isOn: false, windowOpen: false))
        XCTAssertTrue(BackgroundModePolicy.runsWindowServices(isOn: false, windowOpen: true))
    }

    func testTurningOnAlsoLaunchesAtLogin() {
        XCTAssertTrue(BackgroundModePolicy.launchAtLogin(afterTurningOn: true, current: false))
        XCTAssertTrue(BackgroundModePolicy.launchAtLogin(afterTurningOn: false, current: true))
        XCTAssertFalse(BackgroundModePolicy.launchAtLogin(afterTurningOn: false, current: false))
    }

    func testReadsItsOwnDefaultsKeyAndIsOffByDefault() {
        let defaults = UserDefaults(suiteName: "BackgroundModePolicyTests")!
        defaults.removePersistentDomain(forName: "BackgroundModePolicyTests")
        XCTAssertFalse(BackgroundModePolicy.isOn(in: defaults))
        defaults.set(true, forKey: BackgroundModePolicy.defaultsKey)
        XCTAssertTrue(BackgroundModePolicy.isOn(in: defaults))
        defaults.removePersistentDomain(forName: "BackgroundModePolicyTests")
    }
}
