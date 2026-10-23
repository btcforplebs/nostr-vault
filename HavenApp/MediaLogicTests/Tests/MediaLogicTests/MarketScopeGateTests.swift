import XCTest
@testable import MediaLogic

/// Marketplace opens on Following and asks before Global (Logen 2026-10-22).
final class MarketScopeGateTests: XCTestCase {
    func testOpensOnFollowing() {
        XCTAssertFalse(MarketScopeGate.opensOnGlobal)
    }

    func testGlobalWaitsForTheWarningAndFollowingDoesNot() {
        XCTAssertEqual(MarketScopeGate.request(toGlobal: true, currentlyGlobal: false), .warn)
        XCTAssertEqual(MarketScopeGate.request(toGlobal: false, currentlyGlobal: true), .switchScope)
        XCTAssertEqual(MarketScopeGate.request(toGlobal: true, currentlyGlobal: true), .none)
        XCTAssertEqual(MarketScopeGate.request(toGlobal: false, currentlyGlobal: false), .none)
    }

    /// Every way to Global goes through setScope, which consults the gate; and the grid shows the alert.
    func testTheServiceAndTheGridUseIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../HavenApp").standardized
        let service = try String(contentsOf: root.appendingPathComponent("Services/MarketplaceFeedService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("MarketScopeGate.request(toGlobal: newScope == .global"))
        XCTAssertTrue(service.contains("MarketScopeGate.opensOnGlobal ? .global : .following"))
        let grid = try String(contentsOf: root.appendingPathComponent("Views/Feed/FeedView+ModeFeeds.swift"), encoding: .utf8)
        XCTAssertTrue(grid.contains("isPresented: $marketplaceService.globalWarningPending"))
        XCTAssertTrue(grid.contains("marketplaceService.confirmGlobal()"))
    }
}
