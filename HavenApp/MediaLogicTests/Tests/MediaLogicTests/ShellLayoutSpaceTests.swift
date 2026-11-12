import XCTest
@testable import MediaLogic

/// The iPad in landscape is mirrored (Logen, 2026-11-12): Your space on the
/// left like the open Duo's half, the dock's rail on the right.
final class ShellLayoutSpaceTests: XCTestCase {
    func testYourSpaceIsOnTheLeftOnTheIPadAndTheOpenDuo() {
        XCTAssertTrue(ShellLayout.padLandscape.spaceOnLeft)
        XCTAssertTrue(ShellLayout.fold.spaceOnLeft)
        for layout in [ShellLayout.phone, .padUpright, .duoClosed] {
            XCTAssertFalse(layout.spaceOnLeft, "\(layout) has no Your space")
        }
    }

    func testTheDockRailIsOnTheRightInEverySideRailShell() {
        XCTAssertTrue(ShellLayout.padLandscape.dockRailOnRight, "the iPad's rail moved to the right")
        XCTAssertTrue(ShellLayout.fold.dockRailOnRight)
        XCTAssertTrue(ShellLayout.duoClosed.dockRailOnRight)
        XCTAssertFalse(ShellLayout.phone.dockRailOnRight, "the bottom dock")
        XCTAssertFalse(ShellLayout.padUpright.dockRailOnRight, "the bottom dock")
    }

    func testOnlyTheDuoKeepsTheDuoRailMenus() {
        // railOnRight still means the Duo's hold-and-slide rail; the iPad
        // keeps plain taps even though its rail is on the right now.
        XCTAssertFalse(ShellLayout.padLandscape.railOnRight)
        XCTAssertNil(ShellLayout.stripRail(layout: .padLandscape, trailingInset: 20, railWidth: 68),
                     "the iPad has no camera strip")
    }

    func testThePadColumnFoldsToItsRail() {
        XCTAssertEqual(ShellLayout.padSpaceWidth(folded: false, panelsWidth: 340, railWidth: 69), 409)
        XCTAssertEqual(ShellLayout.padSpaceWidth(folded: true, panelsWidth: 340, railWidth: 69), 69)
    }
}
