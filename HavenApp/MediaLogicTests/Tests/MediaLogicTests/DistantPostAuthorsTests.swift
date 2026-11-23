import XCTest
@testable import MediaLogic

/// Discovery design B: who Discover asks the local feed store for. Android
/// twin: `DistantPostAuthorsTest.kt`.
final class DistantPostAuthorsTests: XCTestCase {
    private func pk(_ c: Character) -> String { String(repeating: c, count: 64) }

    private func makeCopy(_ rows: [(Character, Double, Int)]) throws -> TrustRankCopy {
        let me = pk("a")
        let body = rows.map { "[\"\(pk($0.0))\",\($0.1),\($0.2)]" }.joined(separator: ",")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6,"
            + "\"people\":[\(body)],\"viewBar\":55,\"floor\":45}"
        return try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
    }

    func testThePickIsTheAdmittedDistantPeopleHighestScoreFirst() throws {
        let copy = try makeCopy([("b", 100, 1), ("c", 90, 2), ("d", 60, 3), ("e", 80, 4), ("f", 70, 3), ("0", 70, 6)])
        let admitted = DiscoveryReach.admitted(copy, bar: 55)
        XCTAssertEqual(DistantPostAuthors.pick(admitted.distant, copy: copy), [pk("e"), pk("0"), pk("f"), pk("d")],
                       "score order, ties by key; hop 1-2 never")
        XCTAssertEqual(DistantPostAuthors.pick(DiscoveryReach.admitted(copy, bar: 75).distant, copy: copy), [pk("e")],
                       "the bar decides who is asked for")
        XCTAssertEqual(DistantPostAuthors.pick(admitted.distant, copy: nil), [])
    }

    func testThePickStopsAtWhatTheVaultFetches() throws {
        var distant = Set<String>()
        var rows: [String] = []
        for i in 0..<(DistantPostAuthors.max + 20) {
            let key = String(format: "%064x", i + 1)
            distant.insert(key)
            rows.append("[\"\(key)\",\(50 + Double(i % 40)),3]")
        }
        let me = pk("a")
        let text = "{\"account\":\"\(me)\",\"builtAt\":1795300000,\"version\":2,\"maxHop\":6,"
            + "\"people\":[\(rows.joined(separator: ","))],\"viewBar\":55,\"floor\":45}"
        let copy = try XCTUnwrap(TrustRankCopy.parse(Data(text.utf8), account: me))
        let pick = DistantPostAuthors.pick(distant, copy: copy)
        XCTAssertEqual(pick.count, DistantPostAuthors.max)
        XCTAssertEqual(copy.people[pick[0]]?.score, 89)
    }

    func testTheLocalFilterKeepsTheRequestAndSwapsTheAuthors() {
        let base: [String: Any] = ["kinds": [1, 6], "since": 10, "limit": 500, "authors": [pk("c")]]
        XCTAssertNil(DistantPostAuthors.localFilter(base, authors: []))
        let out = DistantPostAuthors.localFilter(base, authors: [pk("e")])
        XCTAssertEqual(out?["authors"] as? [String], [pk("e")])
        XCTAssertEqual(out?["kinds"] as? [Int], [1, 6])
        XCTAssertEqual(out?["since"] as? Int, 10)
        XCTAssertEqual(out?["limit"] as? Int, 500)
    }
}
