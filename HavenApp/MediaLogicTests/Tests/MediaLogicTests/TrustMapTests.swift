import XCTest
@testable import MediaLogic

final class TrustMapTests: XCTestCase {
    private let me = String(repeating: "0", count: 64)
    private let author = String(repeating: "a", count: 64)

    private func key(_ n: Int) -> String { String(format: "%064x", n * 0x1234567 + 1) }

    private func list(_ signer: String, tags: [String], at createdAt: Int = 0) -> [String: Any] {
        ["kind": 3, "pubkey": signer, "created_at": createdAt, "tags": tags.map { ["p", $0] }]
    }

    func testAngleComesFromTheKeyAndStaysPut() {
        XCTAssertEqual(TrustMap.angle(of: "00000000" + String(repeating: "f", count: 56)), 0)
        XCTAssertEqual(TrustMap.angle(of: "80000000" + String(repeating: "f", count: 56)), 180)
        let k = key(42)
        XCTAssertEqual(TrustMap.angle(of: k), TrustMap.angle(of: k))
        // Not hex: still stable and in range.
        let odd = TrustMap.angle(of: "not-a-key")
        XCTAssertEqual(odd, TrustMap.angle(of: "not-a-key"))
        XCTAssert((0..<360).contains(odd))
    }

    func testBandStaysWithinOne() {
        for n in 0..<200 { XCTAssert((-1...1).contains(TrustMap.band(of: key(n)))) }
    }

    func testSpreadPicksEvenlyThroughTheList() {
        let keys = (0..<48).map(key)
        XCTAssertEqual(TrustMap.spread(keys, count: 4), [keys[0], keys[12], keys[24], keys[36]])
        XCTAssertEqual(TrustMap.spread(Array(keys.prefix(3)), count: 12), Array(keys.prefix(3)))
        XCTAssertEqual(TrustMap.spread(keys, count: 0), keys)
    }

    func testNextBatchSkipsSeenAndAuthor() {
        let follows = [key(1), key(2), author, key(3)]
        let filter = TrustMap.nextBatch(author: author, follows: follows, seen: [key(2)])
        XCTAssertEqual(filter?["authors"] as? [String], [key(1), key(3)])
        XCTAssertEqual(filter?["#p"] as? [String], [author])
        XCTAssertEqual(filter?["limit"] as? Int, TrustMap.batchSize)
        XCTAssertNil(TrustMap.nextBatch(author: author, follows: [key(1), author], seen: [key(1)]))
    }

    func testFollowsOfUsesOnlyTheOwnersNewestList() {
        let owner = key(7)
        let lists = [list(owner, tags: [key(1)], at: 100),
                     list(owner, tags: [key(2), key(2), owner, "short"], at: 200),
                     list(key(8), tags: [key(9)], at: 300)]
        XCTAssertEqual(TrustMap.follows(of: owner, in: lists), [key(2)])
        XCTAssertNil(TrustMap.follows(of: key(5), in: lists))
    }

    func testAllBridgesIsUncapped() {
        let follows = Set((1...9).map(key))
        let lists = follows.map { list($0, tags: [author]) }
        let all = TrustPath.allBridges(author: author, me: me, follows: follows, contactLists: lists)
        XCTAssertEqual(all, follows.sorted())
        XCTAssertEqual(TrustPath.resolve(author: author, me: me, follows: follows, trustGraph: ["x"],
                                         contactLists: lists).bridges, Array(all.prefix(5)))
    }

    func testDeeperChains() {
        let bridge = key(1), other = key(2), via = key(3), stranger = key(4)
        let follows: Set<String> = [bridge, other]
        // Seeds: anyone's lists that tag the author. A follow's list is not a
        // middle step (that's 2 hops), and neither is your own.
        let seeds = [list(via, tags: [author]), list(stranger, tags: [author]),
                     list(bridge, tags: [author]), list(me, tags: [author])]
        let viaList = TrustMap.deeperVia(author: author, me: me, follows: follows,
                                         trustGraph: [stranger], seeds: seeds)
        XCTAssertEqual(viaList, [stranger, via], "people in your graph come first")

        let filters = TrustMap.deeperLinkFilters(follows: Array(follows).sorted(), via: viaList)
        XCTAssertEqual(filters.count, 1)
        XCTAssertEqual(filters[0]["#p"] as? [String], viaList)

        // A stranger's list can't invent a route; only your follows' lists count.
        let links = [list(bridge, tags: [via, key(9)]), list(other, tags: [stranger, via]),
                     list(key(5), tags: [via])]
        let chains = TrustMap.chains(me: me, follows: follows, via: viaList, links: links)
        XCTAssertEqual(chains, [TrustMap.Chain(bridge: other, via: stranger),
                                TrustMap.Chain(bridge: bridge, via: via),
                                TrustMap.Chain(bridge: other, via: via)].sorted { ($0.via, $0.bridge) < ($1.via, $1.bridge) })
        XCTAssertTrue(TrustMap.deeperLinkFilters(follows: [bridge], via: []).isEmpty)
    }
}
