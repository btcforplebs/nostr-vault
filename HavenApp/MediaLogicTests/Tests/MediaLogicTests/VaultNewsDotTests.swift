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

    /// The Vault Dashboard (iPhone, iPad and Mac since the one-Vault fold)
    /// sees the news on open, and the tab dot reads the rule.
    func testDashboardsClearTheDot() throws {
        for path in ["HavenApp/Views/Dashboard/VaultDashboardView.swift"] {
            XCTAssertTrue(try source(path).contains("relayManager.markVaultDashboardViewed(dmUnread:"), path)
        }
        let manager = try source("HavenApp/Services/RelayProcessManager.swift")
        let mark = try XCTUnwrap(manager.range(of: "func markVaultDashboardViewed(dmUnread: Int) {"))
        XCTAssertTrue(manager[mark.upperBound...].prefix(200).contains("markRelayViewed(.activity)"))
        let bar = try source("HavenApp-iOS/Shell/BottomTabBar.swift")
        XCTAssertTrue(bar.contains("VaultNewsDot.isShown(newActivity: relayManager.hasNewRelayActivity"))
        XCTAssertTrue(bar.contains("VaultNewsDot.seen(relayManager.dmUnreadSeen, afterUnread: unread)"))
    }

    /// The seen count survives a relaunch, per account (Logen 2026-11-19:
    /// on the iPad, where DMs read on the phone stay unread, the dot came
    /// back after every launch).
    func testSeenCountIsKeptPerAccount() throws {
        let suite = "VaultNewsDotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VaultNewsDot.savedSeen(account: "ab", in: defaults), 0, "never saved")
        VaultNewsDot.saveSeen(3, account: "AB", in: defaults)
        VaultNewsDot.saveSeen(1, account: "cd", in: defaults)
        XCTAssertEqual(VaultNewsDot.savedSeen(account: "ab", in: defaults), 3, "case does not matter")
        XCTAssertEqual(VaultNewsDot.savedSeen(account: "cd", in: defaults), 1)
        VaultNewsDot.saveSeen(9, account: "", in: defaults)
        XCTAssertEqual(VaultNewsDot.savedSeen(account: "", in: defaults), 0, "no account, nothing kept")
    }

    /// The Vault list and Messages see unread DMs, as the dashboard does, and
    /// an account switch takes the saved count, not the in-memory ledger's 0.
    func testListAndMessagesSeeDMsAndSwitchKeepsTheSavedCount() throws {
        let view = try source("HavenApp/Views/Vault/VaultView.swift")
        let hook = try XCTUnwrap(view.range(of: ".onChange(of: modeInSight, initial: true)"))
        let body = view[hook.upperBound...].prefix(500)
        XCTAssertTrue(body.contains("if mode == .activity || mode == .messages {"))
        XCTAssertTrue(body.contains("relayManager.markDMsSeen(unread: DMService.shared.totalUnreadCount)"))
        let state = try source("HavenApp/Services/Relay/VaultNewsState.swift")
        XCTAssertTrue(state.contains("VaultNewsDot.saveSeen(dmUnreadSeen, account: account)"))
        XCTAssertTrue(state.contains("ConfigService.shared.$activeAccountHexPubkey"))
        let dot = try source("HavenApp/Services/Relay/RelayProcessManager+NewsDot.swift")
        XCTAssertFalse(dot.contains("dmUnreadSeen = next.dmSeen"), "the switch would reset the saved count")
    }
}
