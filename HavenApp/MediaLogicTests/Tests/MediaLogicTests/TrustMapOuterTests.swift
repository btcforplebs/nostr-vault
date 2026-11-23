import XCTest
@testable import MediaLogic

/// The globe's outer rings from the desktop Vault's rank. Android twin:
/// `TrustMapOuterTest.kt`.
final class TrustMapOuterTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private var me: String { pk("a") }

    /// b hop 1, c hop 2, d hop 3 at 70, e hop 3 at 80, f hop 3 at 50,
    /// 0 hop 4 at 60, 1 hop 6 at 90.
    private func makeCopy() throws -> TrustRankCopy {
        let rows = [("b", 100, 1), ("c", 80, 2), ("d", 70, 3), ("e", 80, 3), ("f", 50, 3), ("0", 60, 4), ("1", 90, 6)]
            .map { "[\"\(pk(Character($0.0)))\",\($0.1),\($0.2)]" }.joined(separator: ",")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6,"
            + "\"people\":[\(rows)],\"viewBar\":55,\"floor\":45}"
        return try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
    }

    func testRankedRingsHoldOnlyPeopleThreeOrMoreHopsOutOverTheBarBestFirst() throws {
        let outer = TrustMapOuter.make(copy: try makeCopy(), bar: 55, desktopPaired: true)
        XCTAssertEqual(outer.source, .ranked)
        XCTAssertFalse(outer.isFaint)
        XCTAssertEqual(outer.rings.map(\.hop), [3, 4, 6], "no ring 5: nobody is there")
        XCTAssertEqual(outer.rings[0].count, 2, "f is under the bar")
        XCTAssertEqual(outer.rings[0].top, [pk("e"), pk("d")])
        XCTAssertEqual(outer.rings[2].top, [pk("1")])
        XCTAssertEqual(TrustMapOuter.chipText(outer.rings[0]), "3 hops · 2")
        XCTAssertEqual(TrustMapOuter.countText(outer.rings[2], bar: 55), "1 person at score 55 and up.")
    }

    func testABlockedPersonIsLeftOut() throws {
        let outer = TrustMapOuter.make(copy: try makeCopy(), bar: 55, desktopPaired: true, hidden: [pk("e")])
        XCTAssertEqual(outer.rings[0].top, [pk("d")])
        XCTAssertEqual(outer.rings[0].count, 1)
    }

    func testARankCopyCountsEvenWithNoDesktopInTheDeviceList() throws {
        XCTAssertEqual(TrustMapOuter.make(copy: try makeCopy(), bar: 55, desktopPaired: false).source, .ranked)
    }

    func testNoRankDrawsFaintRingsAndInvitesOnlyWithoutADesktopVault() {
        let invite = TrustMapOuter.make(copy: nil, bar: nil, desktopPaired: false)
        XCTAssertEqual(invite.source, .invite)
        XCTAssertTrue(invite.isFaint)
        XCTAssertEqual(invite.rings.map(\.hop), [3, 4, 5])
        XCTAssertTrue(invite.rings.allSatisfy { $0.count == 0 && $0.top.isEmpty })
        XCTAssertEqual(TrustMapOuter.make(copy: nil, bar: nil, desktopPaired: true).source, .waiting)
    }

    func testOnlyAMacOrTheDesktopItselfCountsAsADesktopVault() {
        let phone = MeshDevice(npub: "npub1p", name: "", role: .phone)
        let mac = MeshDevice(npub: "npub1m", name: "", role: .mac)
        let android = MeshDevice(npub: "npub1h", name: "", role: .homeVault)
        XCTAssertFalse(TrustMapOuter.desktopPaired([phone, android], isDesktop: false))
        XCTAssertTrue(TrustMapOuter.desktopPaired([phone, mac], isDesktop: false))
        XCTAssertTrue(TrustMapOuter.desktopPaired([], isDesktop: true))
    }

    func testTheWordsNeverSayHaven() {
        for text in [TrustMapOuter.foundLabel, TrustMapOuter.waitingLabel, TrustMapOuter.pairLine] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("haven"), text)
        }
    }
}
