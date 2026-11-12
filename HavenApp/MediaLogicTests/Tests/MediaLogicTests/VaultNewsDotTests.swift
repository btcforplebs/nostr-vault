import XCTest
@testable import MediaLogic

/// The Vault tab's red dot clears when the Vault Dashboard opens, not only
/// the Vault list (Logen, 2026-11-12). Unread DMs stay unread there; the dot
/// lights again only for a newer one.
final class VaultNewsDotTests: XCTestCase {
    func testNewActivityDots() {
        XCTAssertTrue(VaultNewsDot.isShown(newActivity: true, dmUnread: 0, dmUnreadSeen: 0))
        XCTAssertFalse(VaultNewsDot.isShown(newActivity: false, dmUnread: 0, dmUnreadSeen: 0))
    }

    func testDMsTheDashboardShowedDoNotDot() {
        XCTAssertTrue(VaultNewsDot.isShown(newActivity: false, dmUnread: 2, dmUnreadSeen: 0))
        XCTAssertFalse(VaultNewsDot.isShown(newActivity: false, dmUnread: 2, dmUnreadSeen: 2))
        XCTAssertTrue(VaultNewsDot.isShown(newActivity: false, dmUnread: 3, dmUnreadSeen: 2), "a newer DM dots")
    }

    /// Reading DMs lowers the seen count, so the next DM dots again.
    func testReadingLowersTheSeenCount() {
        let seen = VaultNewsDot.seen(3, afterUnread: 0)
        XCTAssertEqual(seen, 0)
        XCTAssertTrue(VaultNewsDot.isShown(newActivity: false, dmUnread: 1, dmUnreadSeen: seen))
        XCTAssertEqual(VaultNewsDot.seen(1, afterUnread: 4), 1, "a new DM never raises it")
    }

    private static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    /// Both dashboards (iPhone/iPad Vault Dashboard, Mac relay dashboard)
    /// see the news on open, and the tab dot reads the rule.
    func testDashboardsClearTheDot() throws {
        for path in ["HavenApp/Views/Dashboard/VaultDashboardView.swift", "HavenApp/Views/Dashboard/DashboardView.swift"] {
            XCTAssertTrue(try source(path).contains("relayManager.markVaultDashboardViewed(dmUnread:"), path)
        }
        let manager = try source("HavenApp/Services/RelayProcessManager.swift")
        let mark = try XCTUnwrap(manager.range(of: "func markVaultDashboardViewed(dmUnread: Int) {"))
        XCTAssertTrue(manager[mark.upperBound...].prefix(200).contains("markRelayViewed(.activity)"))
        let bar = try source("HavenApp-iOS/Shell/BottomTabBar.swift")
        XCTAssertTrue(bar.contains("VaultNewsDot.isShown(newActivity: relayManager.hasNewRelayActivity"))
        XCTAssertTrue(bar.contains("VaultNewsDot.seen(relayManager.dmUnreadSeen, afterUnread: unread)"))
    }
}
