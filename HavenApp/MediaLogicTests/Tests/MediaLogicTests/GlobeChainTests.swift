import XCTest
@testable import MediaLogic

/// A hop sphere person's path in to you (Logen 2026-11-25).
final class GlobeChainTests: XCTestCase {
    private func pk(_ i: Int) -> String { String(format: "%064x", i) }
    private var me: String { pk(0xa) }

    /// Follow 1; hop 2: 2 (via 1); hop 3: 3 (via 2); hop 4: 4 (via 3), 5 (via 6, unknown).
    private func copy() throws -> TrustRankCopy {
        let globe = [
            "[\"\(pk(2))\",60,2,\"\(pk(1))\"]", "[\"\(pk(3))\",50,3,\"\(pk(2))\"]",
            "[\"\(pk(4))\",40,4,\"\(pk(3))\"]", "[\"\(pk(5))\",30,4,\"\(pk(6))\"]",
        ].joined(separator: ",")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":5,"
            + "\"people\":[[\"\(pk(1))\",100,1]],\"globe\":[\(globe)],\"viewBar\":55,\"floor\":0}"
        return try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
    }

    func testHop4WalksInThroughEveryRingToAFollow() throws {
        let links = GlobeChain.links(from: pk(4), copy: try copy(), follows: [pk(1)])
        XCTAssertEqual(links.map(\.key), [pk(4), pk(3), pk(2), pk(1)])
        XCTAssertEqual(links.map(\.hop), [4, 3, 2, 1])
    }

    func testAnUnknownLinkEndsTheWalkThere() throws {
        let links = GlobeChain.links(from: pk(5), copy: try copy(), follows: [pk(1)])
        XCTAssertEqual(links.map(\.key), [pk(5), pk(6)])
        XCTAssertEqual(links.last?.hop, nil)
    }

    func testNoCopyOrNotOnTheGlobeIsNoPath() throws {
        XCTAssertEqual(GlobeChain.links(from: pk(4), copy: nil, follows: []), [])
        XCTAssertEqual(GlobeChain.links(from: pk(99), copy: try copy(), follows: []), [])
    }
}
