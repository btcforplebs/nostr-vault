import XCTest
@testable import MediaLogic

/// The globe's outer rings from the desktop Vault's rank. Android twin:
/// `TrustMapOuterTest.kt`.
final class TrustMapOuterTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private var me: String { pk("a") }

    /// people: b hop 1, c hop 2, d hop 3 at 70, e hop 3 at 80.
    /// globe: ring 3 top e 80, d 70, f 12 (under the floor, only in globe);
    /// ring 4 top 0 at 20; ring 5 top 1 at 5; then links c (hop 2).
    private func makeCopy() throws -> TrustRankCopy {
        let rows = [("b", 100, 1), ("c", 80, 2), ("d", 70, 3), ("e", 80, 3)]
            .map { "[\"\(pk(Character($0.0)))\",\($0.1),\($0.2)]" }.joined(separator: ",")
        let globe = [("e", 80, 3, "c"), ("d", 70, 3, "c"), ("f", 12, 3, "c"), ("0", 20, 4, "e"), ("1", 5, 5, "0"),
                     ("c", 80, 2, "b")]
            .map { "[\"\(pk(Character($0.0)))\",\($0.1),\($0.2),\"\(pk(Character($0.3)))\"]" }.joined(separator: ",")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6,"
            + "\"people\":[\(rows)],\"globe\":[\(globe)],\"viewBar\":55,\"floor\":45}"
        return try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
    }

    func testRankedRingsAreTheGlobeListsTopPerHopWithNoBar() throws {
        let outer = TrustMapOuter.make(copy: try makeCopy(), desktopPaired: true)
        XCTAssertEqual(outer.source, .ranked)
        XCTAssertFalse(outer.isFaint)
        XCTAssertEqual(outer.rings.map(\.hop), [3, 4, 5], "hop-2 link rows are not a ring")
        XCTAssertEqual(outer.rings[0].top, [pk("e"), pk("d"), pk("f")], "file order, f at 12 is in: no bar")
        XCTAssertEqual(outer.rings[2].top, [pk("1")])
        XCTAssertEqual(TrustMapOuter.chipText(outer.rings[0]), "3 hops · top 3")
        XCTAssertFalse(TrustMapOuter.chipText(outer.rings[0]).contains("55"))
        XCTAssertEqual(TrustMapOuter.countText(outer.rings[2]),
                       "The 1 best-scored person in this ring, whatever their score.")
    }

    func testOnlyARingsFirst300RowsAreItsTopLaterRowsAreLinks() throws {
        let hex = (0..<301).map { String(format: "%064x", $0 + 1) }
        let link = String(repeating: "c", count: 64)
        let globe = hex.enumerated().map { "[\"\($1)\",\(90 - Double($0) / 10),3,\"\(link)\"]" }
            + ["[\"\(link)\",80,2,\"\(pk("b"))\"]"]
        let text = "{\"account\":\"\(me)\",\"builtAt\":1,\"version\":2,\"maxHop\":6,"
            + "\"people\":[[\"\(pk("b"))\",100,1]],\"globe\":[\(globe.joined(separator: ","))]}"
        let copy = try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
        let ring = try XCTUnwrap(TrustMapOuter.make(copy: copy, desktopPaired: true).rings.first)
        XCTAssertEqual(ring.top.count, 300)
        XCTAssertEqual(ring.top.first, hex[0])
        XCTAssertFalse(ring.top.contains(hex[300]), "row 301 of a hop is a chain link, not on the ring")
        XCTAssertEqual(TrustMapOuter.chipText(ring), "3 hops · top 300")
    }

    func testAZeroRowIsALinkEvenInARingUnder300() throws {
        // haven-go's top leaves out anyone who shows 0, so in a ring with
        // fewer than 300 scored people a 0 row is a chain link.
        let link = String(repeating: "c", count: 64)
        let globe = ["[\"\(pk("d"))\",40,3,\"\(link)\"]", "[\"\(pk("e"))\",30,4,\"\(pk("9"))\"]",
                     "[\"\(pk("9"))\",0,3,\"\(link)\"]", "[\"\(link)\",80,2,\"\(pk("b"))\"]"]
        let text = "{\"account\":\"\(me)\",\"builtAt\":1,\"version\":2,\"maxHop\":6,"
            + "\"people\":[[\"\(pk("b"))\",100,1]],\"globe\":[\(globe.joined(separator: ","))]}"
        let copy = try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
        let outer = TrustMapOuter.make(copy: copy, desktopPaired: true)
        XCTAssertEqual(outer.rings.first?.top, [pk("d")], "9 shows 0: a link to e, not a dot")
        XCTAssertEqual(TrustMapOuter.countText(try XCTUnwrap(outer.rings.first)),
                       "The 1 best-scored person in this ring, whatever their score.")
    }

    func testFadesPerHop() {
        XCTAssertEqual(TrustMapOuter.fade(hop: 3), 1)
        XCTAssertEqual(TrustMapOuter.fade(hop: 4), 0.6)
        XCTAssertEqual(TrustMapOuter.fade(hop: 5), 0.35)
    }

    func testACopyWithNoGlobeListDrawsNoRings() throws {
        let text = "{\"account\":\"\(me)\",\"builtAt\":1,\"version\":2,\"maxHop\":4,"
            + "\"people\":[[\"\(pk("d"))\",90,3]]}"
        let copy = try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me), "an older engine's file still reads")
        XCTAssertTrue(copy.globe.isEmpty)
        let outer = TrustMapOuter.make(copy: copy, desktopPaired: true)
        XCTAssertEqual(outer.source, .ranked)
        XCTAssertTrue(outer.rings.isEmpty, "rings come from the globe list only, not from people")
    }

    func testABlockedPersonIsLeftOut() throws {
        let outer = TrustMapOuter.make(copy: try makeCopy(), desktopPaired: true, hidden: [pk("e")])
        XCTAssertEqual(outer.rings[0].top, [pk("d"), pk("f")])
        XCTAssertEqual(outer.rings[0].count, 2)
    }

    func testARankCopyCountsEvenWithNoDesktopInTheDeviceList() throws {
        XCTAssertEqual(TrustMapOuter.make(copy: try makeCopy(), desktopPaired: false).source, .ranked)
    }

    func testNoRankDrawsFaintRingsAndInvitesOnlyWithoutADesktopVault() {
        let invite = TrustMapOuter.make(copy: nil, desktopPaired: false)
        XCTAssertEqual(invite.source, .invite)
        XCTAssertTrue(invite.isFaint)
        XCTAssertEqual(invite.rings.map(\.hop), [3, 4, 5])
        XCTAssertTrue(invite.rings.allSatisfy { $0.count == 0 && $0.top.isEmpty })
        XCTAssertEqual(TrustMapOuter.make(copy: nil, desktopPaired: true).source, .waiting)
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
