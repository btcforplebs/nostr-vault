import XCTest
@testable import MediaLogic

/// A key on screen is covered from the moment the app resigns active until
/// it is active again, so the app-switcher card never shows it.
final class KeySnapshotShieldTests: XCTestCase {

    private func covered(after moments: [KeySnapshotShield.Moment]) -> Bool {
        moments.reduce(false) { _, moment in KeySnapshotShield.covered(after: moment) }
    }

    func testSwipingUpToTheSwitcherCoversTheKey() {
        XCTAssertTrue(covered(after: [.willResignActive]))
    }

    func testBackgroundKeepsTheKeyCovered() {
        XCTAssertTrue(covered(after: [.willResignActive, .didEnterBackground]))
    }

    func testForegroundAloneDoesNotUncover() {
        // The app is still inactive here; the switcher may still be up.
        XCTAssertTrue(covered(after: [.willResignActive, .didEnterBackground, .willEnterForeground]))
    }

    func testBecomingActiveUncovers() {
        XCTAssertFalse(covered(after: [.willResignActive, .didEnterBackground, .willEnterForeground, .didBecomeActive]))
        XCTAssertFalse(covered(after: [.willResignActive, .didBecomeActive]))
    }
}
