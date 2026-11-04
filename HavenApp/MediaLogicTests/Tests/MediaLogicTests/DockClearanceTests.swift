import XCTest
@testable import MediaLogic

/// Floating buttons and full-bleed screens take the dock's band off what they
/// clear, since the root's safe area already holds it (build 60: a dock too high).
final class DockClearanceTests: XCTestCase {
    func testBandIsTheRootInset() {
        XCTAssertEqual(DockClearance.band(dockHeight: 114.6, keyboardUp: false), 115, "same whole points as the root inset")
        XCTAssertEqual(DockClearance.band(dockHeight: 114, keyboardUp: true), 0, "above the keyboard the dock is a SwiftUI inset, not safe area")
        XCTAssertEqual(DockClearance.band(dockHeight: 0, keyboardUp: false), 0, "no dock, no band")
    }

    func testBandMatchesDockInset() {
        for height in [0, 60.4, 114.6] as [CGFloat] {
            for keyboardUp in [false, true] {
                let placement = DockInset.placement(dockShown: height > 0, keyboardUp: keyboardUp)
                XCTAssertEqual(DockClearance.band(dockHeight: height, keyboardUp: keyboardUp),
                               DockInset.rootBottom(placement: placement, dockHeight: height))
            }
        }
    }

    func testRemaining() {
        XCTAssertEqual(DockClearance.remaining(114.6, band: 115), 0, "the band covers the whole dock")
        XCTAssertEqual(DockClearance.remaining(114, band: 0), 114, "keyboard up: clear it by hand, as before")
        XCTAssertEqual(DockClearance.remaining(60, band: 0), 60)
    }
}
