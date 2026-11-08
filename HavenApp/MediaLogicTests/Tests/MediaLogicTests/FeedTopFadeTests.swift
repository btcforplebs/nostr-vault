import XCTest
@testable import MediaLogic

/// The band behind the iPhone feed's top pills (Logen 2026-11-08).
final class FeedTopFadeTests: XCTestCase {
    /// The clock's part is solid, then the fade: Android GlassScaffold's stops.
    func testSolidBehindTheClockThenFadesToClear() {
        // iPhone 18 Pro: 62 pt clock + 44 pt bar.
        let stops = FeedTopFade.stops(statusBar: 62, total: 106)
        let solid = 62.0 / 106.0
        XCTAssertEqual(stops.count, 4)
        XCTAssertEqual(stops[0], .init(location: 0, opacity: 1))
        XCTAssertEqual(stops[1].location, solid, accuracy: 1e-9)
        XCTAssertEqual(stops[1].opacity, 1)
        XCTAssertEqual(stops[2].location, solid + (1 - solid) * 0.7, accuracy: 1e-9)
        XCTAssertEqual(stops[2].opacity, 0.7)
        XCTAssertEqual(stops[3], .init(location: 1, opacity: 0))
    }

    /// Never all solid: the bottom of the band always fades out.
    func testSolidPartIsCapped() {
        let stops = FeedTopFade.stops(statusBar: 200, total: 100)
        XCTAssertEqual(stops[1].location, 0.9, accuracy: 1e-9)
        XCTAssertEqual(stops.last?.opacity, 0)
        XCTAssertEqual(FeedTopFade.stops(statusBar: 0, total: 0), [])
    }

    /// The bug: no band at all on any feed type. Every feed but Reels shows
    /// it on the iPhone; the iPad's floating bar has its own edge.
    func testShownOnEveryFeedButReelsOnTheIPhone() {
        XCTAssertTrue(FeedTopFade.shows(isReels: false, floatingBar: false))
        XCTAssertFalse(FeedTopFade.shows(isReels: true, floatingBar: false))
        XCTAssertFalse(FeedTopFade.shows(isReels: false, floatingBar: true))
    }
}
