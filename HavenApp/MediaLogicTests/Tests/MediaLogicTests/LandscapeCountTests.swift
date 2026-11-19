import XCTest
import CoreGraphics
@testable import MediaLogic

/// Full-screen viewers share one landscape slot count: the phone goes
/// upright only when the last one closes.
final class LandscapeCountTests: XCTestCase {
    func testOpenOpenCloseStaysAllowedThenLastCloseTurnsUpright() {
        var count = LandscapeCount()
        XCTAssertFalse(count.allowsLandscape)
        count.opened()
        count.opened()
        XCTAssertFalse(count.closed(), "one viewer still open")
        XCTAssertTrue(count.allowsLandscape)
        XCTAssertTrue(count.closed(), "last close asks for upright")
        XCTAssertFalse(count.allowsLandscape)
    }

    func testExtraCloseDoesNothing() {
        var count = LandscapeCount()
        XCTAssertFalse(count.closed())
        XCTAssertEqual(count.open, 0)
        count.opened()
        XCTAssertTrue(count.allowsLandscape)
    }

    /// A wide clip no longer turns the phone by itself (Logen 2026-11-19);
    /// the viewers still hold a slot, so turning the phone yourself rotates.
    func testViewersDoNotAutoTurnButStillAllowTurning() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["HavenApp/Views/MediaViewer/FeedMediaViewer.swift",
                     "HavenApp/Views/MediaGallery/MediaGalleryViewer.swift",
                     "HavenApp/Views/MediaViewer/LandscapeAllowance.swift"] {
            let source = try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("turnsSidewaysForWideClip"), path)
            XCTAssertFalse(source.contains("turnSidewaysIfWide"), path)
            XCTAssertTrue(source.contains("landscapeSlot("), path)
        }
    }

    /// Photos and GIFs never turn the screen; only the clip on screen may,
    /// and a closing viewer gives its slot up before it zooms away.
    func testOnlyTheClipOnScreenHoldsASlot() {
        XCTAssertTrue(LandscapeCount.pageHolds(isClip: true, isOnScreen: true, isClosing: false))
        XCTAssertFalse(LandscapeCount.pageHolds(isClip: false, isOnScreen: true, isClosing: false), "photo")
        XCTAssertFalse(LandscapeCount.pageHolds(isClip: true, isOnScreen: false, isClosing: false), "neighbour page")
        XCTAssertFalse(LandscapeCount.pageHolds(isClip: true, isOnScreen: true, isClosing: true), "closing")
    }
}
