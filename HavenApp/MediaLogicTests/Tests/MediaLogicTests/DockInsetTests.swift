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

    func testRootInsetOnlyForTheBand() {
        XCTAssertEqual(DockInset.rootBottom(placement: .rootBand, dockHeight: 83.4), 83)
        XCTAssertEqual(DockInset.rootBottom(placement: .swiftUIInset, dockHeight: 83), 0)
        XCTAssertEqual(DockInset.rootBottom(placement: .none, dockHeight: 83), 0)
        XCTAssertEqual(DockInset.rootBottom(placement: .rootBand, dockHeight: -3), 0)
    }
}
