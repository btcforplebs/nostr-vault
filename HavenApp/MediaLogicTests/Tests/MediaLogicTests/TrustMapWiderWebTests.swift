import XCTest
@testable import MediaLogic

/// Someone else's globe: their web from their follows' lists, and the layer
/// picker still lighting your part of it.
final class TrustMapWiderWebTests: XCTestCase {
    private func key(_ n: Int) -> String { String(format: "%064x", n) }
    private let center = String(format: "%064x", 9_999)

    private func list(_ signer: String, follows: [String], at: Int = 100) -> [String: Any] {
        ["kind": 3, "pubkey": signer, "created_at": at, "tags": follows.map { ["p", $0] }]
    }

    func testWiderWebCountsHowManyOfTheirFollowsNameEachPerson() {
        let (a, b, c) = (key(1), key(2), key(3))
        let ring = [a, b, c]
        let lists = [
            list(a, follows: [key(10), key(11), center]),
            list(b, follows: [key(10), c]),
            list(c, follows: [key(10)]),
        ]
        let wider = TrustMap.widerWeb(of: center, ring: ring, lists: lists)
        XCTAssertEqual(wider.vouches[key(10)], 3)
        XCTAssertEqual(wider.vouches[key(11)], 1)
        XCTAssertEqual(wider.vouches[c], 1, "a follow named by another follow still counts")
        XCTAssertNil(wider.vouches[center], "the core is never in their own web")
        XCTAssertEqual(wider.graph, [key(10), key(11), c])
    }

    func testWiderWebTakesTheNewestListAndOnlyTheirFollows() {
        let a = key(1)
        let lists = [
            list(a, follows: [key(20)], at: 100),
            list(a, follows: [key(21)], at: 200),
            list(key(50), follows: [key(22)]),
            ["kind": 1, "pubkey": a, "created_at": 300, "tags": [["p", key(23)]]],
        ]
        let wider = TrustMap.widerWeb(of: center, ring: [a], lists: lists)
        XCTAssertEqual(wider.graph, [key(21)])
    }

    func testWiderSampleIsCappedAndStable() {
        let ring = (1...500).map(key)
        let sample = TrustMap.widerSample(ring)
        XCTAssertEqual(sample.count, TrustMap.widerSampleCap)
        XCTAssertEqual(sample, TrustMap.widerSample(ring.reversed()))
        XCTAssertEqual(TrustMap.widerSample([key(1)]), [key(1)])
    }

    func testLayerLitIsAboutYou() {
        let me = key(0)
        let follows: Set<String> = [me, key(1), key(2)]
        let web: Set<String> = [key(1), key(2), key(3), key(4)]
        let vouches = [key(3): TrustMap.closeVouches, key(4): 1]
        XCTAssertNil(TrustMap.layerLit(.everyone, me: me, follows: follows, web: web, vouches: vouches))
        XCTAssertEqual(TrustMap.layerLit(.following, me: me, follows: follows, web: web, vouches: vouches), [key(1), key(2)])
        XCTAssertEqual(TrustMap.layerLit(.close, me: me, follows: follows, web: web, vouches: vouches), [key(3)])
        XCTAssertEqual(TrustMap.layerLit(.furtherOut, me: me, follows: follows, web: web, vouches: vouches), [key(4)])
    }
}
