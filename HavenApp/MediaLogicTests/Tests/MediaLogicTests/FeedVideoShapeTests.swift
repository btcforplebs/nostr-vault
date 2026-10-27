import XCTest
@testable import MediaLogic

/// Feed videos play at their own shape: a portrait box for portrait video,
/// capped in height by narrowing, never by cropping.
final class FeedVideoShapeTests: XCTestCase {

    func testRatioNeedsBothSides() {
        XCTAssertEqual(FeedVideoShape.ratio(of: CGSize(width: 720, height: 1280))!, 0.5625, accuracy: 0.0001)
        XCTAssertNil(FeedVideoShape.ratio(of: .zero))
        XCTAssertNil(FeedVideoShape.ratio(of: CGSize(width: 720, height: 0)))
    }

    func testPortraitGetsTheTallerCapButNoMoreThanTheCeiling() {
        XCTAssertEqual(FeedVideoShape.heightCap(ratio: 9.0 / 16.0, landscapeCap: 400, portraitCap: 600), FeedVideoShape.portraitCeiling)
        // A caller with a smaller portrait cap keeps it.
        XCTAssertEqual(FeedVideoShape.heightCap(ratio: 9.0 / 16.0, landscapeCap: 150, portraitCap: 200), 200)
    }

    func testLandscapeSquareAndUnknownKeepTheLandscapeCap() {
        XCTAssertEqual(FeedVideoShape.heightCap(ratio: 16.0 / 9.0, landscapeCap: 400, portraitCap: 600), 400)
        XCTAssertEqual(FeedVideoShape.heightCap(ratio: 1, landscapeCap: 400, portraitCap: 600), 400)
        XCTAssertEqual(FeedVideoShape.heightCap(ratio: nil, landscapeCap: 400, portraitCap: 600), 400)
    }

    func testPortraitNarrowsSoItFitsUnderTheCapWhole() {
        let ratio: CGFloat = 9.0 / 16.0
        let cap = FeedVideoShape.heightCap(ratio: ratio, landscapeCap: 400, portraitCap: 600)
        let width = FeedVideoShape.maxWidth(ratio: ratio, heightCap: cap)
        XCTAssertEqual(width, 292.5, accuracy: 0.001)
        // At that width the video's own height is exactly the cap: no crop.
        XCTAssertEqual(width / ratio, cap, accuracy: 0.001)
    }

    func testLandscapeIsOnlyLimitedPastItsCap() {
        // A 16:9 box is 400 tall only at 711pt wide; a phone column never is.
        XCTAssertGreaterThan(FeedVideoShape.maxWidth(ratio: 16.0 / 9.0, heightCap: 400), 700)
        XCTAssertEqual(FeedVideoShape.maxWidth(ratio: nil, heightCap: 400), .infinity)
    }
}
