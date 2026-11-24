import XCTest
@testable import MediaLogic

/// Feed media ··· showed Delete on someone else's photo (2026-11-23).
final class MediaDeleteGateTests: XCTestCase {
    private let me = String(repeating: "a", count: 64)
    private let them = String(repeating: "b", count: 64)

    func testSomeoneElsesMediaHasNoDelete() {
        XCTAssertFalse(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: them, activePubkey: me))
    }

    func testYourOwnMediaHasDelete() {
        XCTAssertTrue(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: me, activePubkey: me))
        XCTAssertTrue(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: me.uppercased(), activePubkey: me))
    }

    func testUnknownPosterOrAccountHasNoDelete() {
        XCTAssertFalse(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: nil, activePubkey: me))
        XCTAssertFalse(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: "", activePubkey: me))
        XCTAssertFalse(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: "", activePubkey: ""))
        XCTAssertFalse(MediaDeleteGate.showsDelete(screenOwnsDelete: false, poster: me, activePubkey: ""))
    }

    func testScreenWithItsOwnDeleteKeepsIt() {
        XCTAssertTrue(MediaDeleteGate.showsDelete(screenOwnsDelete: true, poster: them, activePubkey: me))
        XCTAssertTrue(MediaDeleteGate.showsDelete(screenOwnsDelete: true, poster: nil, activePubkey: me))
    }
}
