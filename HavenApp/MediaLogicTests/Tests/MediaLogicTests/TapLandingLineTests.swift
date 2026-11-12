import XCTest
@testable import MediaLogic

final class TapLandingLineTests: XCTestCase {

    /// 20 pt under the buttons: the bar edge is 10 pt below them.
    func testLineIsTenPointsUnderTheBarEdge() {
        XCTAssertEqual(TapLandingLine.gap, 10)
    }

    /// The anchor puts a zero-height marker `gap` points down, whatever the
    /// viewport: iPhone, iPad, a Mac window.
    func testAnchorLandsOnTheSamePointForEveryViewport() {
        for height: CGFloat in [568, 724, 1180, 1600] {
            let y = TapLandingLine.anchorY(viewportHeight: height)
            XCTAssertEqual(y * height, TapLandingLine.gap, accuracy: 0.001, "viewport \(height)")
        }
    }

    func testAnchorBeforeLayoutIsTheTop() {
        XCTAssertEqual(TapLandingLine.anchorY(viewportHeight: 0), 0)
        XCTAssertEqual(TapLandingLine.anchorY(viewportHeight: 5), 0)
    }

    /// The last row's top can scroll up to the line, however short it is.
    func testBottomRoomLetsTheLastPostReachTheLine() {
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724), 714)
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 0), 0)
    }

    /// A long thread under the opened post needs no room: its end is the
    /// end of the scroll, not a screen of nothing (the black page).
    func testNoRoomWhenTheContentBelowFillsTheScreen() {
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724, contentBelowTop: 2000), 0)
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724, contentBelowTop: 714), 0)
    }

    /// A short post near the end gets only what is missing to reach the line.
    func testRoomIsOnlyWhatIsMissing() {
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724, contentBelowTop: 300), 414)
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724, contentBelowTop: 0), 714)
    }

    /// Not measured yet (or a bad measure): the full room, so the landing still works.
    func testUnmeasuredOrNegativeFallsBackToFullRoom() {
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 724, contentBelowTop: -50), 714)
        XCTAssertEqual(TapLandingLine.bottomRoom(viewportHeight: 0, contentBelowTop: 300), 0)
    }
}
