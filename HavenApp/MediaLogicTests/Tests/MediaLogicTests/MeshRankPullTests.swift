import XCTest
@testable import MediaLogic

/// Rank only: which paired desktops a phone pulls the rank from with no
/// first copy, the signed start's tags, and the engine's end line.
final class MeshRankPullTests: XCTestCase {
    private let mac = "npub1" + String(repeating: "m", count: 58)
    private let box = "npub1" + String(repeating: "b", count: 58)
    private let phone = "npub1" + String(repeating: "p", count: 58)

    private var devices: [MeshDevice] {
        [MeshDevice(npub: mac, name: "Studio", role: .mac), MeshDevice(npub: box, name: "Box", role: .mac),
         MeshDevice(npub: phone, name: "Pad", role: .phone)]
    }

    func testEveryPairedDesktopNotCopiedFrom() {
        XCTAssertEqual(MeshRankPull.peers(devices, copied: [:], pending: nil), [mac, box], "no first copy: both desktops")
        XCTAssertEqual(MeshRankPull.peers(devices, copied: [mac: 5], pending: nil), [box], "a copied Mac keeps its catch-up")
        XCTAssertEqual(MeshRankPull.peers(devices, copied: [:], pending: box), [mac], "not the pending copy's device")
        XCTAssertFalse(MeshRankPull.peers(devices, copied: [:], pending: nil).contains(phone), "never a phone")
    }

    func testDueOncePerHour() {
        let hour = Int(MeshRankNudge.recheckEvery)
        XCTAssertEqual(MeshRankPull.due(devices, copied: [:], pending: nil, pulledAt: [:], now: 1000), [mac, box])
        XCTAssertEqual(MeshRankPull.due(devices, copied: [:], pending: nil, pulledAt: [mac: 1000, box: 1000 - hour], now: 1000), [box])
    }

    func testStartTagsNameTheRankPath() {
        let tags = MeshRankPull.startTags(base: URL(string: "http://127.0.0.1:4242/ingress-secret")!, receiver: mac)
        XCTAssertEqual(tags, [["u", "http://127.0.0.1:4242/copy/v2/rank-start"], ["method", "POST"], ["p", mac]],
                       "the ingress path never goes in the proof")
        XCTAssertNil(MeshRankPull.startTags(base: URL(string: "http://127.0.0.1:4242")!, receiver: " "))
    }

    /// The lines as haven-go's startRankPull logs them (copyv2_rank_only_test.go checks the same form).
    func testEndLine() {
        XCTAssertEqual(MeshRankPull.parse("2026/11/25 10:00:00 RANK_PULLED peer=\(mac) got=1"),
                       .init(peer: mac, got: 1, error: ""))
        XCTAssertEqual(MeshRankPull.parse("2026/11/25 10:00:00 RANK_PULLED peer=\(mac) got=0 error=auth_refused"),
                       .init(peer: mac, got: 0, error: "auth_refused"))
        XCTAssertNil(MeshRankPull.parse("XRANK_PULLED peer=\(mac) got=1"))
        XCTAssertNil(MeshRankPull.parse("RANK_PULLED peer=npub1short got=1"))
        XCTAssertNil(MeshRankPull.parse("RANK_READY peer=\(mac)"))
    }
}
