import XCTest
@testable import MediaLogic

/// The trust rank nudge lines, and a phone relearning the devices it copied
/// from when it never read the first copy's done line (LogePhone, 2026-11-23).
final class MeshRankNudgeTests: XCTestCase {
    private let mac = "npub1" + String(repeating: "q", count: 58)

    func testTheEnginesDoneLineIsRead() {
        // Exactly what haven-go copyv2_client.go now writes at the end of a first copy.
        let line = "2026/11/23 10:54:52 COPY stage=done part=- bytes=0/0 items=29373/29373 source=mesh notes=24686 messages=3191 files=1496 left_out=0 not_caught_up="
        XCTAssertEqual(MeshCopyV2.parseLine(line)?.stage, "done")
    }

    func testReadyAndBuiltLines() {
        XCTAssertEqual(MeshRankNudge.readyPeer("2026/11/23 12:00:00 RANK_READY peer=\(mac)"), mac)
        XCTAssertNil(MeshRankNudge.readyPeer("2026/11/23 12:00:00 RANK_READY peer=npub1short"))
        XCTAssertNil(MeshRankNudge.readyPeer("xRANK_READY peer=\(mac)"))
        XCTAssertTrue(MeshRankNudge.isBuilt("2026/11/23 12:00:00 RANK_BUILT account=61bf790b"))
        XCTAssertFalse(MeshRankNudge.isBuilt("trust rank: 61bf790b… ranked 9 people"))
    }

    func testTheParserHandsThemOn() {
        var batch = RelayLogParser.BatchedStateUpdate()
        RelayLogParser.collectStateChanges(from: "2026/11/23 12:00:00 RANK_READY peer=\(mac)", into: &batch)
        RelayLogParser.collectStateChanges(from: "2026/11/23 12:00:00 RANK_BUILT account=61bf790b", into: &batch)
        XCTAssertEqual(batch.rankReadyPeers, [mac])
        XCTAssertTrue(batch.rankBuilt)
        XCTAssertTrue(RelayLogParser.isCritical(batch))
    }

    func testNudgeKeepsTheIngressPathButSignsWithoutIt() throws {
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:3360/abc123"))
        XCTAssertEqual(MeshRankNudge.nudgeURL(base: base)?.absoluteString, "http://127.0.0.1:3360/abc123/copy/v2/nudge")
        XCTAssertEqual(MeshRankNudge.tags(base: base, receiver: mac),
                       [["u", "http://127.0.0.1:3360/copy/v2/nudge"], ["method", "POST"], ["p", mac]])
    }

    func testAdoptBringsBackLostDevicesDueNow() {
        var r = MeshCopyV2.Record()
        XCTAssertTrue(r.syncDue(now: 10_000).isEmpty)
        r.adopt([mac])
        XCTAssertEqual(r.syncDue(now: 10_000), [mac])
    }

    func testAdoptKeepsTimesAndThePendingCopy() {
        var r = MeshCopyV2.Record()
        r.copied = [mac: 9_000]
        r.pending = .init(peer: "npub1pad", name: "iPad", freshStart: true)
        r.adopt([mac, "npub1pad"])
        XCTAssertEqual(r.copied, [mac: 9_000])
    }
}
