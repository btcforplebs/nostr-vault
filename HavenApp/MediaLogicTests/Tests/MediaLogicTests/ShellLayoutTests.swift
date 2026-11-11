import XCTest
@testable import MediaLogic

/// The iOS shell per device and window. The iPhone Duo (closed 466 x 678 pt,
/// open 669 x 951 pt) gets three shells; every other device is as before.
final class ShellLayoutTests: XCTestCase {
    func testOtherIPhonesKeepThePhoneLayout() {
        // 13 mini upright, 17 Pro Max upright and landscape (it reports regular width there).
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 375, height: 812)), .phone)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 440, height: 956)), .phone)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 956, height: 440)), .padLandscape,
                       "a Pro Max on its side keeps what it had")
    }

    func testDuoClosedIsThePhoneWithARightRail() {
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 466, height: 678)), .duoClosed)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 678, height: 466)), .duoClosed,
                       "on its side too, whatever size class it reports")
    }

    func testDuoOpenSidewaysIsTheFold() {
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 951, height: 669)), .fold)
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 951, height: 669)), .fold)
    }

    func testDuoOpenUprightIsThePlainPhone() {
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: true, window: CGSize(width: 669, height: 951)), .phone,
                       "the feed alone, full screen, bottom dock")
        XCTAssertEqual(ShellLayout.pick(isPhone: true, regularWidth: false, window: CGSize(width: 669, height: 951)), .phone)
    }

    func testIPadsAreUnchanged() {
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: true, window: CGSize(width: 1133, height: 744)), .padLandscape)
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: true, window: CGSize(width: 744, height: 1133)), .padUpright)
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: false, window: CGSize(width: 320, height: 1133)), .phone,
                       "slide over")
        XCTAssertEqual(ShellLayout.pick(isPhone: false, regularWidth: false, window: CGSize(width: 507, height: 744)), .phone,
                       "a half-width iPad window is not a closed Duo")
    }

    /// Folding, unfolding and turning the Duo must not swap the view tree
    /// under the app, or the tab loses its scroll position: no Duo shell
    /// uses the note split.
    func testDuoShellsShareOneViewTree() {
        let duo: [ShellLayout] = [.duoClosed, .fold, .phone]
        XCTAssertEqual(Set(duo.map(\.usesNoteSplit)), [false])
        XCTAssertTrue(ShellLayout.padUpright.usesNoteSplit)
        XCTAssertTrue(ShellLayout.padLandscape.usesNoteSplit)
    }

    func testRails() {
        XCTAssertTrue(ShellLayout.duoClosed.hasSideRail)
        XCTAssertTrue(ShellLayout.duoClosed.railOnRight)
        XCTAssertTrue(ShellLayout.fold.hasSideRail)
        XCTAssertTrue(ShellLayout.fold.railOnRight)
        XCTAssertTrue(ShellLayout.padLandscape.hasSideRail)
        XCTAssertFalse(ShellLayout.padLandscape.railOnRight)
        XCTAssertFalse(ShellLayout.padUpright.hasSideRail)
        XCTAssertFalse(ShellLayout.phone.hasSideRail)
    }

    /// Closed Duo: the rail sits inside iOS's camera strip on the right,
    /// below the camera, as wide as the strip.
    func testDuoClosedRailGoesInsideTheCameraStrip() {
        let rail = ShellLayout.stripRail(layout: .duoClosed, trailingInset: 85, railWidth: 68)
        XCTAssertEqual(rail, ShellLayout.StripRail(topClearance: ShellLayout.duoStripTopClearance, width: 85))
        XCTAssertEqual(ShellLayout.stripRail(layout: .duoClosed, trailingInset: 40, railWidth: 68)?.width, 68,
                       "never narrower than the rail")
    }

    /// Open on its side the strip is still on the right (Logen, 2026-11-11).
    func testDuoOpenRailGoesInsideTheCameraStrip() {
        XCTAssertEqual(ShellLayout.stripRail(layout: .fold, trailingInset: 85, railWidth: 68),
                       ShellLayout.StripRail(topClearance: ShellLayout.duoStripTopClearance, width: 85))
    }

    func testNoStripRailWithoutAStripOnTheRight() {
        XCTAssertNil(ShellLayout.stripRail(layout: .duoClosed, trailingInset: 0, railWidth: 68),
                     "the closed Duo turned so the strip is elsewhere")
        XCTAssertNil(ShellLayout.stripRail(layout: .fold, trailingInset: 0, railWidth: 68),
                     "the open Duo turned so the strip is elsewhere")
        for layout in [ShellLayout.phone, .padLandscape, .padUpright] {
            XCTAssertNil(ShellLayout.stripRail(layout: layout, trailingInset: 85, railWidth: 68), "\(layout)")
        }
    }

    /// The left half ends on the screen's middle, after whatever safe area is
    /// already on the left.
    func testLeftHalfEndsBeforeTheFold() {
        let w: CGFloat = 1000
        let left = ShellLayout.foldLeftWidth(windowWidth: w, leadingInset: 0)
        XCTAssertEqual(left, w / 2)
        XCTAssertEqual(ShellLayout.foldLeftWidth(windowWidth: w, leadingInset: 24) + 24, w / 2)
        XCTAssertEqual(ShellLayout.foldLeftWidth(windowWidth: 0, leadingInset: 24), 0)
    }
}
