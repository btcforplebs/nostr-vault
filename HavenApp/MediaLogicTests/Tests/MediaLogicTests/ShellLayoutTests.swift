import XCTest
@testable import MediaLogic

/// The iOS shell per device and window: the open folding iPhone gets "Your
/// space" left of the fold and the app right of it; everything else is as before.
final class ShellLayoutTests: XCTestCase {
    func testClosedIPhonesKeepThePhoneLayout() {
        // 13 mini upright, 17 Pro Max upright and landscape (it reports regular width there).
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 375, height: 812)), .phone)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 440, height: 956)), .phone)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 956, height: 440)), .padLandscape,
                       "a Pro Max on its side keeps what it had")
    }

    func testOpenFoldingIPhoneIsTheFoldLayoutEitherWay() {
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 900, height: 700)), .fold)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 700, height: 900)), .fold,
                       "the size class it reports does not matter")
    }

    func testIPadsAreUnchanged() {
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: true, window: CGSize(width: 1133, height: 744)), .padLandscape)
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: true, window: CGSize(width: 744, height: 1133)), .padUpright)
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: false, window: CGSize(width: 320, height: 1133)), .phone,
                       "slide over")
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: true, window: CGSize(width: 1133, height: 744), forceFold: true), .fold,
                       "the debug switch that shows it on an iPad sim")
    }

    func testRailAndSplit() {
        XCTAssertFalse(ShellLayout.phone.usesNoteSplit)
        XCTAssertTrue(ShellLayout.fold.usesNoteSplit)
        XCTAssertTrue(ShellLayout.fold.hasSideRail)
        XCTAssertTrue(ShellLayout.padLandscape.hasSideRail)
        XCTAssertFalse(ShellLayout.padUpright.hasSideRail)
        XCTAssertFalse(ShellLayout.phone.hasSideRail)
    }

    /// The left half stops half a gutter short of the screen's middle, after
    /// whatever safe area is already on the left.
    func testLeftHalfEndsBeforeTheFold() {
        let w: CGFloat = 1000
        let left = ShellLayout.foldLeftWidth(windowWidth: w, leadingInset: 0)
        XCTAssertEqual(left + ShellLayout.foldGutter / 2, w / 2)
        XCTAssertEqual(ShellLayout.foldLeftWidth(windowWidth: w, leadingInset: 24) + 24 + ShellLayout.foldGutter / 2, w / 2)
        XCTAssertEqual(ShellLayout.foldLeftWidth(windowWidth: 0, leadingInset: 24), 0)
    }
}
