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
