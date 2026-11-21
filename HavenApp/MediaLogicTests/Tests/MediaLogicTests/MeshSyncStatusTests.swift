import XCTest
@testable import MediaLogic

/// Settings › Your Devices › Sync with your vaults (3.3.0 A4). Same cases as
/// Android's MeshSyncStatusTest (D1), so the two say the same thing.
final class MeshSyncStatusTests: XCTestCase {
    private let now = 1_767_000_000
    private let mac = MeshDevice(npub: "npub1mac", name: "Studio Mac", role: .mac)
    private let box = MeshDevice(npub: "npub1box", name: "", role: .homeVault)
    private let phone = MeshDevice(npub: "npub1phone", name: "Pixel", role: .phone)

    func testOnlyDevicesCopiedFromGetARowInTheListsOrder() {
        let sync = MeshSyncState(lastAt: ["npub1box": now - 300, "npub1mac": now - 7200, "npub1gone": now])
        let rows = MeshSyncStatus.rows(devices: [mac, box, phone], sync: sync, progress: nil, now: now)
        XCTAssertEqual(rows.map(\.name), ["Studio Mac", MeshDeviceRole.homeVault.label])
        XCTAssertEqual(rows.map(\.lastLine), ["Last synced 2 h ago", "Last synced 5 min ago"])
        XCTAssertEqual(rows.map(\.state), [.upToDate, .upToDate])
    }

    func testARunningFirstCopyGetsARowBeforeItHasSynced() {
        let rows = MeshSyncStatus.rows(devices: [mac], sync: MeshSyncState(running: "npub1mac"), progress: nil, now: now)
        XCTAssertEqual(rows.map(\.lastLine), ["Never synced"])
        XCTAssertEqual(rows.map(\.stateLine), ["Syncing…"])
    }

    func testTheStateFollowsRunningWaitingAndFailed() {
        let sync = MeshSyncState(lastAt: ["npub1mac": now, "npub1box": now, "npub1phone": now], running: "npub1mac",
                                 queued: ["npub1box"], failed: ["npub1phone": "unreachable", "npub1mac": "x"])
        XCTAssertEqual(MeshSyncStatus.state("npub1mac", sync: sync), .syncing)
        XCTAssertEqual(MeshSyncStatus.state("npub1box", sync: sync), .waiting)
        XCTAssertEqual(MeshSyncStatus.state("npub1phone", sync: sync), .failed)
    }

    func testStateLines() {
        let fetching = MeshCopyV2.Progress(stage: "fetching", part: "media", bytes: (25, 100), items: (0, 1),
                                           source: "mesh", error: "")
        XCTAssertEqual(MeshSyncStatus.stateLine(.syncing, error: nil, progress: fetching), "Syncing… 25%")
        XCTAssertEqual(MeshSyncStatus.stateLine(.syncing, error: nil, progress: nil), "Syncing…")
        XCTAssertTrue(MeshSyncStatus.stateLine(.failed, error: "unreachable", progress: nil).hasPrefix("Couldn't reach it"))
        XCTAssertEqual(MeshSyncStatus.stateLine(.failed, error: "hash_mismatch", progress: nil), "The last sync didn't finish.")
        XCTAssertEqual(MeshSyncStatus.stateLine(.waiting, error: nil, progress: nil), "Waiting to sync")
        XCTAssertEqual(MeshSyncStatus.stateLine(.upToDate, error: nil, progress: nil), "Up to date")
        XCTAssertEqual(MeshSyncStatus.lastLine(0, now: now), "Never synced")
        XCTAssertEqual(MeshSyncStatus.lastLine(now - 10, now: now), "Last synced just now")
    }

    func testSyncNowIsOffBeforeSetupWithNothingToSyncOrWhileOneRunsOrWaits() {
        let sync = MeshSyncState(lastAt: ["npub1mac": now])
        let rows = MeshSyncStatus.rows(devices: [mac], sync: sync, progress: nil, now: now)
        XCTAssertTrue(MeshSyncStatus.syncEnabled(setupDone: true, rows: rows, sync: sync))
        XCTAssertFalse(MeshSyncStatus.syncEnabled(setupDone: false, rows: rows, sync: sync))
        XCTAssertFalse(MeshSyncStatus.syncEnabled(setupDone: true, rows: [], sync: sync))
        var running = sync; running.running = "npub1mac"
        XCTAssertFalse(MeshSyncStatus.syncEnabled(setupDone: true, rows: rows, sync: running))
        var waiting = sync; waiting.queued = ["npub1mac"]
        XCTAssertFalse(MeshSyncStatus.syncEnabled(setupDone: true, rows: rows, sync: waiting))
    }

    /// Longest ago first, due or not; never the pending copy's device or the
    /// one already running.
    func testSyncNowOrder() {
        let copied = ["npub1a": now - 10, "npub1b": now - 9_000, "npub1c": now - 500, "npub1p": now - 99_999]
        XCTAssertEqual(MeshSyncStatus.syncNowOrder(copied: copied, pending: "npub1p", running: nil),
                       ["npub1b", "npub1c", "npub1a"])
        XCTAssertEqual(MeshSyncStatus.syncNowOrder(copied: copied, pending: nil, running: "npub1b"),
                       ["npub1p", "npub1c", "npub1a"])
        XCTAssertEqual(MeshSyncStatus.syncNowOrder(copied: [:], pending: nil, running: nil), [])
    }

    func testQueueHasNoRepeatsAndNotTheRunningOne() {
        XCTAssertEqual(MeshSyncStatus.queued(["npub1a"], adding: ["npub1b", "npub1a", "npub1r"], running: "npub1r"),
                       ["npub1a", "npub1b"])
    }
}
