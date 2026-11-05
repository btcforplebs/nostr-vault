import XCTest
@testable import MediaLogic

/// The log lines that move the menu bar's Booting / Syncing / Online.
final class RelayLogParserStatusTests: XCTestCase {
    private func batch(_ lines: String...) -> RelayLogParser.BatchedStateUpdate {
        var b = RelayLogParser.BatchedStateUpdate()
        for line in lines { RelayLogParser.collectStateChanges(from: line, into: &b) }
        return b
    }

    /// A refused or failed start is read, with its reason, so the app leaves
    /// "Booting…" at once.
    func testAFailedStartIsRead() {
        let b = batch("2026/11/05 09:00:00 🚫 RELAY_START_FAILED|relay could not listen on 127.0.0.1:3355: listen tcp 127.0.0.1:3355: bind: address already in use")
        XCTAssertEqual(b.startFailed?.hasPrefix("relay could not listen"), true)
        XCTAssertTrue(b.isPortConflict)
        XCTAssertFalse(b.stopBooting)
        XCTAssertNil(batch("🚫 relay HTTP server exited: something").startFailed)
    }

    /// "Syncing" ends at the inbox subscription, not at the line saying it
    /// waits for the Web of Trust first.
    func testSyncingEndsOnlyAtTheInboxSubscription() {
        XCTAssertFalse(batch("📢 waiting for Web of Trust before subscribing to inbox").stopWotSyncing)
        XCTAssertTrue(batch("📢 subscribing to inbox on 4 relays (import + DM)").stopWotSyncing)
    }

    /// While the window is closed, batches that change what the menu bar
    /// shows are still applied.
    func testMenuBarChangesAreCritical() {
        XCTAssertTrue(RelayLogParser.isCritical(batch("📢 subscribing to inbox on 4 relays (import + DM)")))
        XCTAssertTrue(RelayLogParser.isCritical(batch("🚫 RELAY_START_FAILED|refused")))
        var conn = RelayLogParser.BatchedStateUpdate()
        conn.connectionsDelta = 1
        XCTAssertTrue(RelayLogParser.isCritical(conn))
        var dot = RelayLogParser.BatchedStateUpdate()
        dot.inboxActivityKinds = [1]
        XCTAssertTrue(RelayLogParser.isCritical(dot))
        XCTAssertFalse(RelayLogParser.isCritical(batch("some ordinary line")))
    }
}
