import XCTest
@testable import MediaLogic

/// The soft fade behind the iPhone feed's top pills.
final class FeedTopFadeTests: XCTestCase {
    /// Every feed but Reels shows it on the iPhone; the iPad's floating bar
    /// has its own edge.
    func testShownOnEveryFeedButReelsOnTheIPhone() {
        XCTAssertTrue(FeedTopFade.shows(isReels: false, floatingBar: false))
        XCTAssertFalse(FeedTopFade.shows(isReels: true, floatingBar: false))
        XCTAssertFalse(FeedTopFade.shows(isReels: false, floatingBar: true))
    }
}
