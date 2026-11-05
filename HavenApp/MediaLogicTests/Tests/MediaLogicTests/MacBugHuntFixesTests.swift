import XCTest
@testable import MediaLogic

/// Mac bug hunt 2026-11-05: the phone's web-address check before pairing,
/// and the dashboard's Mac row. (The Add deadline is MeshPairingConfirmWindow.)
final class MacBugHuntFixesTests: XCTestCase {
    func testAMacSetByWebAddressIsRefusedBeforePairing() {
        XCTAssertTrue(MeshPairing.macSetByWebAddress(role: .mac, macRelayURL: "https://mac.example", macRelayMeshNpub: nil))
        XCTAssertFalse(MeshPairing.macSetByWebAddress(role: .mac, macRelayURL: "npub1x", macRelayMeshNpub: "npub1x"))
        XCTAssertFalse(MeshPairing.macSetByWebAddress(role: .mac, macRelayURL: "  ", macRelayMeshNpub: nil))
        XCTAssertFalse(MeshPairing.macSetByWebAddress(role: .phone, macRelayURL: "https://mac.example", macRelayMeshNpub: nil))
    }

    private func status(_ state: String, url: String = "https://mac.example", finished: Int64 = 1_700_000_000) -> RelayConfiguration.MacSyncStatus {
        var s = try! JSONDecoder().decode(RelayConfiguration.MacSyncStatus.self, from: Data("{}".utf8))
        s.macURL = url
        s.state = state
        s.finishedAt = finished
        return s
    }

    /// The Mac row never says "synced" for a copy that failed, or for
    /// another Mac.
    func testTheMacRowSaysWhatHappenedForThisMac() {
        let rel: (Date) -> String = { _ in "2 min ago" }
        let url = "https://mac.example"
        XCTAssertEqual(RelayConfiguration.macSyncRowDetail(status("done"), macURL: url, relative: rel), "Copied from your Mac 2 min ago.")
        XCTAssertTrue(RelayConfiguration.macSyncRowDetail(status("failed"), macURL: url, relative: rel).hasPrefix("Couldn't reach your Mac"))
        XCTAssertTrue(RelayConfiguration.macSyncRowDetail(status("incomplete"), macURL: url, relative: rel).hasPrefix("Last copy didn't finish"))
        XCTAssertEqual(RelayConfiguration.macSyncRowDetail(status("done", url: "https://other-mac.example"), macURL: url, relative: rel),
                       "Set up. Not synced yet.")
        XCTAssertTrue(RelayConfiguration.macSyncRowDetail(nil, macURL: "", relative: rel).hasPrefix("Not set up"))
    }
}
