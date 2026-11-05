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
