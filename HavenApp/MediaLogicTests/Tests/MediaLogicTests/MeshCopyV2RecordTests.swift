import XCTest
@testable import MediaLogic

/// B's record of the mesh copy: what resumes, what restarts, what is
/// forgotten, and when a linked device is due a catch-up.
final class MeshCopyV2RecordTests: XCTestCase {
    private let peer = "npub1peer"

    private func line(_ s: String) throws -> MeshCopyV2.Progress { try XCTUnwrap(MeshCopyV2.parseLine(s)) }

    private func pending() -> MeshCopyV2.Record {
        var r = MeshCopyV2.Record()
        r.pending = .init(peer: peer, name: "Mac", freshStart: true)
        return r
    }

    func testDoneMarksCopiedAndClearsPending() throws {
        var r = pending()
        r.finished(try line("COPY stage=done part=- bytes=0/0 items=5/5 source=mesh"), peer: peer, now: 100)
        XCTAssertNil(r.pending)
        XCTAssertEqual(r.copied, [peer: 100])
    }

    func testUnreachableResumesWithTheHeldToken() throws {
        var r = pending()
        r.finished(try line("COPY stage=failed part=media bytes=1/9 items=0/1 source=mesh error=unreachable"), peer: peer, now: 1)
        XCTAssertEqual(r.pending?.freshStart, false)
        XCTAssertTrue(r.copied.isEmpty)
    }

    func testDamagedCopyStartsOverWithAFreshStart() throws {
        var r = pending()
        r.pending?.freshStart = false
        r.finished(try line("COPY stage=failed part=notes bytes=0/9 items=0/3 source=mesh error=hash_mismatch"), peer: peer, now: 1)
        XCTAssertEqual(r.pending?.freshStart, true)
    }

    func testAStopIsNotRetried() throws {
        for code in ["needs_space", "not_owner", "auth_refused", "unsupported_version", "no_space"] {
            var r = pending()
            r.finished(try line("COPY stage=failed part=- bytes=1/2 items=0/0 source=mesh error=\(code)"), peer: peer, now: 1)
            XCTAssertNil(r.pending, code)
        }
    }

    func testRunningLinesChangeNothing() throws {
        var r = pending()
        r.finished(try line("COPY stage=fetching part=media bytes=1/2 items=0/1 source=mesh"), peer: peer, now: 1)
        XCTAssertEqual(r, pending())
    }

    func testCatchUpIsDueOncePerWindowAndNotWhilePending() {
        var r = MeshCopyV2.Record()
        r.copied = ["npub1a": 0, "npub1b": 1000]
        XCTAssertEqual(r.syncDue(now: MeshCopyV2.syncEvery), ["npub1a"])
        XCTAssertEqual(r.syncDue(now: 1000 + MeshCopyV2.syncEvery), ["npub1a", "npub1b"])
        r.pending = .init(peer: "npub1a", name: "", freshStart: false)
        XCTAssertEqual(r.syncDue(now: 1000 + MeshCopyV2.syncEvery), ["npub1b"])
    }
}

/// Remove device: B forgets the peer, so nothing resumes or catches up with it.
final class MeshCopyV2ForgetTests: XCTestCase {
    func testForgetDropsPendingAndCatchUp() {
        var r = MeshCopyV2.Record()
        r.pending = .init(peer: "npub1gone", name: "Old phone", freshStart: false)
        r.copied = ["npub1gone": 0, "npub1kept": 0]
        r.forget("npub1gone")
        XCTAssertNil(r.pending)
        XCTAssertEqual(r.syncDue(now: MeshCopyV2.syncEvery), ["npub1kept"])
    }

    /// Both Remove device sites forget the peer, and forgetting revokes its
    /// copy tokens in the engine (Tron's must-fix). Positive control: each
    /// file is found and holds its removal.
    func testRemoveDeviceRevokesCopyAccess() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HavenApp")
        func source(_ path: String) throws -> String {
            try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
        }
        for path in ["Services/FipsMeshDevices.swift", "Views/Settings/FipsMesh/MacFipsMeshSettingsView.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("MeshDevicesLogic.removing(npub: device.npub"), path)
            XCTAssertTrue(text.contains("MeshCopyV2Service.shared.forget(peer: device.npub)"), path)
        }
        let service = try source("Services/Relay/MeshCopyV2Service.swift")
        let forget = try XCTUnwrap(service.range(of: "func forget(peer: String) {"))
        let body = service[forget.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("RevokeCopyTokensC("), "forget must revoke the device's copy tokens")
    }

    func testForgetLeavesAnotherPeersPending() {
        var r = MeshCopyV2.Record()
        r.pending = .init(peer: "npub1kept", name: "", freshStart: true)
        r.forget("npub1gone")
        XCTAssertEqual(r.pending?.peer, "npub1kept")
    }
}

/// A copy that can't reach the other device is tried again every ~15 s for a
/// few minutes, then fails with Try again (Logen, 2026-11-06).
final class MeshCopyV2UnreachableRetryTests: XCTestCase {
    private let peer = "npub1peer"

    private func line(_ s: String) throws -> MeshCopyV2.Progress { try XCTUnwrap(MeshCopyV2.parseLine(s)) }

    private func pending() -> MeshCopyV2.Record {
        var r = MeshCopyV2.Record()
        r.pending = .init(peer: peer, name: "Mac", freshStart: true)
        return r
    }

    private let unreachable = "COPY stage=failed part=media bytes=1/9 items=0/1 source=mesh error=unreachable"

    func testUnreachableIsTriedAgainEvery15Seconds() throws {
        var r = pending()
        XCTAssertEqual(r.retry(now: 0), .none)
        r.finished(try line(unreachable), peer: peer, now: 100)
        XCTAssertEqual(r.unreachableSince, 100)
        XCTAssertEqual(r.retry(now: 100), .after(15))
        // A second miss keeps the first time: the window runs from the first.
        r.finished(try line(unreachable), peer: peer, now: 135)
        XCTAssertEqual(r.unreachableSince, 100)
        XCTAssertEqual(r.retry(now: 100 + MeshCopyV2.unreachableRetryFor - 1), .after(15))
    }

    func testUnreachableFailsAfterAFewMinutesAndTryAgainStartsOver() throws {
        var r = pending()
        r.finished(try line(unreachable), peer: peer, now: 100)
        XCTAssertEqual(r.retry(now: 100 + MeshCopyV2.unreachableRetryFor), .gaveUp)
        XCTAssertNotNil(r.pending, "Try again still has the copy to resume")
        r.retryNow()
        XCTAssertEqual(r.retry(now: 1000), .none)
        r.missed(peer: peer, now: 1000)
        XCTAssertEqual(r.retry(now: 1000), .after(15))
    }

    func testAMissWithNoMeshLinkCountsLikeTheEnginesLine() {
        var r = pending()
        r.missed(peer: "npub1other", now: 5)
        XCTAssertEqual(r.retry(now: 5), .none, "only the pending copy's device")
        r.missed(peer: peer, now: 5)
        XCTAssertEqual(r.retry(now: 5 + MeshCopyV2.unreachableRetryFor), .gaveUp)
    }

    func testReachingItAgainOrAnyOtherEndStopsTheRetries() throws {
        var r = pending()
        r.finished(try line(unreachable), peer: peer, now: 1)
        r.finished(try line("COPY stage=failed part=notes bytes=0/9 items=0/3 source=mesh error=hash_mismatch"), peer: peer, now: 2)
        XCTAssertNil(r.unreachableSince)
        r.finished(try line(unreachable), peer: peer, now: 3)
        r.finished(try line("COPY stage=done part=- bytes=0/0 items=5/5 source=mesh"), peer: peer, now: 4)
        XCTAssertEqual(r.retry(now: 4), .none)
        XCTAssertNil(r.unreachableSince)
    }

    func testRemovingTheDeviceStopsTheRetries() throws {
        var r = pending()
        r.finished(try line(unreachable), peer: peer, now: 1)
        r.forget(peer)
        XCTAssertEqual(r.retry(now: 2), .none)
        XCTAssertNil(r.unreachableSince)
    }

    func testACatchUpThatCantReachIsNotRetried() throws {
        var r = MeshCopyV2.Record()
        r.copied = [peer: 0]
        r.finished(try line(unreachable), peer: peer, now: 1)
        XCTAssertEqual(r.retry(now: 1), .none)
    }

    func testAnOldSaveWithoutTheFieldStillLoads() throws {
        let old = #"{"pending":{"peer":"npub1peer","name":"Mac","freshStart":false},"copied":{}}"#
        let r = try JSONDecoder().decode(MeshCopyV2.Record.self, from: Data(old.utf8))
        XCTAssertEqual(r.pending?.peer, peer)
        XCTAssertNil(r.unreachableSince)
    }

    func testTheScreenSaysTryingThenFailed() {
        XCTAssertNil(MeshCopyV2.unreachableLine(.none, name: "Mac"))
        XCTAssertEqual(MeshCopyV2.unreachableLine(.after(15), name: "Mac"), "Can't reach Mac yet. Trying again…")
        XCTAssertTrue(MeshCopyV2.unreachableLine(.gaveUp, name: "")?.hasPrefix("Couldn't reach your other device.") == true)
    }
}
