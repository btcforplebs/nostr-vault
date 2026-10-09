import XCTest
@testable import MediaLogic

/// Which active-account changes the services treat as a switch.
final class AccountSwitchTests: XCTestCase {
    func testSwitchBetweenAccounts() {
        XCTAssertTrue(HavenConfig.isAccountSwitch(from: "aa", to: "bb"))
    }

    func testSignOutToNoAccountIsASwitch() {
        XCTAssertTrue(HavenConfig.isAccountSwitch(from: "aa", to: ""))
    }

    /// Setup finishing gives the first account; nothing was loaded for an
    /// earlier one, so there is nothing to switch away from.
    func testFirstAccountIsNotASwitch() {
        XCTAssertFalse(HavenConfig.isAccountSwitch(from: "", to: "aa"))
    }

    func testSameAccountIsNotASwitch() {
        XCTAssertFalse(HavenConfig.isAccountSwitch(from: "aa", to: "aa"))
        XCTAssertFalse(HavenConfig.isAccountSwitch(from: "", to: ""))
    }
}
