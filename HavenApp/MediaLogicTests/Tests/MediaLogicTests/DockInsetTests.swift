import XCTest
@testable import MediaLogic

/// The dock's band is the root's safe area so picture-in-picture keeps clear of it (RESEARCH/NV_PIP_PLAN.md).
final class DockInsetTests: XCTestCase {
    func testPlacement() {
        XCTAssertEqual(DockInset.placement(dockShown: true, keyboardUp: false), .rootBand)
        XCTAssertEqual(DockInset.placement(dockShown: true, keyboardUp: true), .swiftUIInset, "above the keyboard, as before")
        XCTAssertEqual(DockInset.placement(dockShown: false, keyboardUp: false), .none)
        XCTAssertEqual(DockInset.placement(dockShown: false, keyboardUp: true), .none)
    }

    /// Typing hides the dock on every tab and pushed page, not only Search
    /// (a DM thread's message box sat under it, Logen 2026-11-05); iPhone
    /// and iPad upright alike. The iPad landscape rail never has one.
    func testDockHidesWhileTypingAnywhere() {
        XCTAssertTrue(DockInset.shown(keyboardUp: false, sideRail: false))
        XCTAssertFalse(DockInset.shown(keyboardUp: true, sideRail: false), "typing: no dock covering the composer")
        XCTAssertFalse(DockInset.shown(keyboardUp: false, sideRail: true))
        XCTAssertFalse(DockInset.shown(keyboardUp: true, sideRail: true))
        let typing = DockInset.placement(dockShown: DockInset.shown(keyboardUp: true, sideRail: false), keyboardUp: true)
        XCTAssertEqual(typing, .none)
        XCTAssertEqual(DockInset.rootBottom(placement: typing, dockHeight: 83), 0, "no band left behind for the keyboard to sit on")
    }

    func testRootInsetOnlyForTheBand() {
        XCTAssertEqual(DockInset.rootBottom(placement: .rootBand, dockHeight: 83.4), 83)
        XCTAssertEqual(DockInset.rootBottom(placement: .swiftUIInset, dockHeight: 83), 0)
        XCTAssertEqual(DockInset.rootBottom(placement: .none, dockHeight: 83), 0)
        XCTAssertEqual(DockInset.rootBottom(placement: .rootBand, dockHeight: -3), 0)
    }
}
