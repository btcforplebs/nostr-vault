import XCTest
@testable import MediaLogic

/// The chain back to you from the globe list's `via` links, and the globe
/// list's checks (docs/MESH_COPY_V2_CONTRACT.md §5). Android twin:
/// `TrustChainTest.kt`.
final class TrustChainTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private var me: String { pk("a") }

    private func file(people: String = "[[\"\(String(repeating: "b", count: 64))\",100,1]]",
                      globe: String, maxHop: Int = 6) -> Data {
        Data(("{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":\(maxHop),"
            + "\"people\":\(people),\"globe\":\(globe),\"viewBar\":55,\"floor\":45}").utf8)
    }

    private func row(_ who: Character, _ score: Double, _ hop: Int, _ via: Character) -> String {
        "[\"\(pk(who))\",\(score),\(hop),\"\(pk(via))\"]"
    }

    /// b (ring 1, people) > c (2) > d (3) > e (4) > f (5).
    private func chainCopy() throws -> TrustRankCopy {
        let globe = "[" + [row("d", 40, 3, "c"), row("e", 20, 4, "d"), row("f", 8, 5, "e"), row("c", 70, 2, "b")]
            .joined(separator: ",") + "]"
        return try XCTUnwrap(TrustRankCopy.parse(file(globe: globe), account: me))
    }

    func testWalksViaBackToYourFollowNearestFirst() throws {
        let copy = try chainCopy()
        XCTAssertEqual(TrustChain.links(to: pk("f"), copy: copy), [pk("b"), pk("c"), pk("d"), pk("e"), pk("f")])
        XCTAssertEqual(TrustChain.links(to: pk("d"), copy: copy), [pk("b"), pk("c"), pk("d")])
        XCTAssertEqual(TrustChain.links(to: pk("c"), copy: copy), [pk("b"), pk("c")], "a hop-2 link row")
        XCTAssertEqual(TrustChain.links(to: pk("D"), copy: copy)?.last, pk("d"), "keys in any case")
    }

    func testTheChainReadsYouThenNames() throws {
        let links = try XCTUnwrap(TrustChain.links(to: pk("d"), copy: try chainCopy()))
        let names = [pk("b"): "Alice", pk("c"): "Bob", pk("d"): "Carol"]
        XCTAssertEqual(TrustChain.text(links, name: { names[$0] ?? "?" }), "You > Alice > Bob > Carol")
    }

    func testNoChainForSomeoneNotOnTheGlobeListOrABrokenChain() throws {
        let copy = try chainCopy()
        XCTAssertNil(TrustChain.links(to: pk("9"), copy: copy))
        XCTAssertNil(TrustChain.links(to: pk("b"), copy: copy), "ring 1 is in people, not the globe list")
        XCTAssertNil(TrustChain.links(to: pk("d"), copy: nil))
        // d's link is missing.
        let missing = try XCTUnwrap(TrustRankCopy.parse(file(globe: "[\(row("d", 40, 3, "c"))]"), account: me))
        XCTAssertNil(TrustChain.links(to: pk("d"), copy: missing))
        // e's via is two rings in, not one.
        let skip = try XCTUnwrap(TrustRankCopy.parse(
            file(globe: "[\(row("e", 20, 4, "c")),\(row("c", 70, 2, "b"))]"), account: me))
        XCTAssertNil(TrustChain.links(to: pk("e"), copy: skip))
        // c's via is not one of your follows (an unfollow since the rank).
        let unfollowed = try XCTUnwrap(TrustRankCopy.parse(
            file(people: "[]", globe: "[\(row("d", 40, 3, "c")),\(row("c", 70, 2, "b"))]"), account: me))
        XCTAssertNil(TrustChain.links(to: pk("d"), copy: unfollowed))
    }

    func testWhyGivesTheChainAndAScoreForSomeoneOnlyOnTheGlobeList() throws {
        let copy = try chainCopy()
        XCTAssertNil(copy[pk("e")], "e is under the floor: not in people")
        let why = try XCTUnwrap(TrustWhy.of(pubkey: pk("e"), me: me, copy: copy, path: nil))
        XCTAssertEqual(why.score, 20)
        XCTAssertEqual(why.hop, 4)
        XCTAssertEqual(why.chain, [pk("b"), pk("c"), pk("d"), pk("e")])
        XCTAssertEqual(TrustWhyText.chain(why, name: { String($0.prefix(1)) }), "You > b > c > d > e")
    }

    func testTheGlobeListNeverChangesTheFeedRows() throws {
        let copy = try chainCopy()
        XCTAssertEqual(copy.people.keys.sorted(), [pk("b")], "globe rows stay out of people")
        XCTAssertNil(copy[pk("c")])
    }

    func testABadGlobeRowRefusesTheWholeCopy() {
        let bad = [
            "[[\"\(pk("d"))\",40,3]]",                              // no via
            "[[\"\(pk("d"))\",40,3,\"zz\"]]",                       // via not hex
            "[[\"\(pk("d"))\",101,3,\"\(pk("c"))\"]]",              // over 100
            "[[\"\(pk("d"))\",40,6,\"\(pk("c"))\"]]",               // past GlobeHop
            "[[\"\(pk("d"))\",40,1,\"\(pk("c"))\"]]",               // ring 1 is not a globe ring
            "[[\"\(pk("d"))\",40,3.5,\"\(pk("c"))\"]]",             // not a whole hop
            "[[\"\(pk("d"))\",\"40\",3,\"\(pk("c"))\"]]",           // quoted number
            "{}",
        ]
        for globe in bad {
            XCTAssertNil(TrustRankCopy.parse(file(globe: globe), account: me), globe)
        }
        XCTAssertNil(TrustRankCopy.parse(file(globe: "[\(row("e", 20, 4, "d"))]", maxHop: 3), account: me),
                     "a globe ring past maxHop")
        XCTAssertNotNil(TrustRankCopy.parse(file(globe: "null"), account: me))
    }

    func testTheRowCapIsTheContractsAndIsKept() throws {
        // docs/MESH_COPY_V2_CONTRACT.md says the cap; the code must agree.
        let contract = try String(contentsOf: MeshCopyV2Tests.fixtures
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MESH_COPY_V2_CONTRACT.md"), encoding: .utf8)
        let match = try XCTUnwrap(contract.firstMatch(of: #/most ([0-9,]+) globe rows/#))
        let cap = try XCTUnwrap(Int(match.1.replacingOccurrences(of: ",", with: "")))
        XCTAssertEqual(TrustRankCopy.maxGlobeRows, cap)
        XCTAssertTrue(contract.contains("top \(TrustRankCopy.globePerRing)"))

        let rows = (0..<cap).map { "[\"\(String(format: "%064x", $0 + 1))\",10,3,\"\(pk("c"))\"]" }
        XCTAssertNotNil(TrustRankCopy.parse(file(globe: "[" + rows.joined(separator: ",") + "]"), account: me))
        let over = rows + ["[\"\(pk("e"))\",10,3,\"\(pk("c"))\"]"]
        XCTAssertNil(TrustRankCopy.parse(file(globe: "[" + over.joined(separator: ",") + "]"), account: me))
    }
}
