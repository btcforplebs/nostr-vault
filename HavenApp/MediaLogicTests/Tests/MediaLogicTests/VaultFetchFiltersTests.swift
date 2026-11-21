import XCTest
@testable import MediaLogic

/// The Vault's fetch filters (Logen 2026-11-21: iOS Vault showed no likes).
/// A relay answers each filter with its newest `limit` matches, so whatever
/// shares a filter with kind 3 lists competes with them for that limit.
final class VaultFetchFiltersTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let noteKinds = [1, 6, 30023, 1111, 9802, 1068]

    private struct Event: Hashable {
        let id: String
        let kind: Int
        let author: String
        let createdAt: Int64
        let p: String?
    }

    /// Newest-N per filter, then the union: how a relay (and the store) answers.
    private func answer(_ filters: [[String: Any]], from events: [Event]) -> Set<Event> {
        var out = Set<Event>()
        for f in filters {
            let kinds = f["kinds"] as? [Int] ?? []
            let authors = f["authors"] as? [String]
            let p = (f["#p"] as? [String])?.first
            let until = f["until"] as? Int64
            let since = f["since"] as? Int64
            let limit = f["limit"] as? Int ?? .max
            let matches = events.filter { e in
                kinds.contains(e.kind)
                    && (authors == nil || authors!.contains(e.author))
                    && (p == nil || e.p == p)
                    && (until == nil || e.createdAt <= until!)
                    && (since == nil || e.createdAt >= since!)
            }
            out.formUnion(matches.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
        }
        return out
    }

    /// 300 followers' kind 3 lists and 40 DMs tag you, all newer than the
    /// likes, reposts and zaps you got.
    private func crowdedWindow() -> [Event] {
        var events: [Event] = []
        var t: Int64 = 1_000_000
        func add(_ kind: Int, _ n: Int) {
            for i in 0..<n {
                t += 1
                events.append(Event(id: "\(kind)-\(i)", kind: kind, author: "other\(i)", createdAt: t, p: owner))
            }
        }
        add(7, 30)
        add(16, 5)
        add(9735, 10)
        add(3, 300)
        add(4, 40)
        return events
    }

    private func filters(until: Int64? = nil) -> [[String: Any]] {
        VaultFetchFilters.filters(ownerHex: owner, authors: [owner], until: until, since: nil, noteKinds: noteKinds)
    }

    func testLikesSurviveTwoHundredFollowerLists() {
        let got = answer(filters(), from: crowdedWindow())
        XCTAssertEqual(got.filter { $0.kind == 7 }.count, 30)
        XCTAssertEqual(got.filter { $0.kind == 16 }.count, 5)
        XCTAssertEqual(got.filter { $0.kind == 9735 }.count, 10)
    }

    /// The old shared filter, as a control: the same window loses every like.
    func testTheSharedFilterLostThem() {
        let shared: [String: Any] = ["kinds": [0, 3, 4, 7, 1063, 9735, 10000, 10063], "#p": [owner], "limit": 200]
        let got = answer([shared], from: crowdedWindow())
        XCTAssertEqual(got.filter { $0.kind == 7 }.count, 0)
    }

    func testTaggedEngagementHasItsOwnFilter() {
        let tagged = filters().filter { ($0["#p"] as? [String]) == [owner] }
        let engagement = tagged.filter { ($0["kinds"] as? [Int]) == [7, 16, 9735] }
        XCTAssertEqual(engagement.count, 1)
        XCTAssertEqual(engagement.first?["limit"] as? Int, 500)
        // No other #p filter shares those kinds.
        for f in tagged where differs(f, engagement.first) {
            let kinds = Set(f["kinds"] as? [Int] ?? [])
            XCTAssertTrue(kinds.isDisjoint(with: [7, 16, 9735]), "\(kinds)")
        }
    }

    func testOlderPageUsesAndroidsOlderLimit() {
        let engagement = filters(until: 5).first { ($0["kinds"] as? [Int]) == [7, 16, 9735] }
        XCTAssertEqual(engagement?["limit"] as? Int, 200)
        XCTAssertEqual(engagement?["until"] as? Int64, 5)
    }

    func testOwnLikesStayInTheAuthorFilter() {
        let authorMeta = filters().first { ($0["authors"] as? [String]) == [owner] && (($0["kinds"] as? [Int]) ?? []).contains(0) }
        XCTAssertTrue((authorMeta?["kinds"] as? [Int])?.contains(7) == true)
    }

    private func differs(_ a: [String: Any], _ b: [String: Any]?) -> Bool {
        guard let b else { return true }
        return (a["kinds"] as? [Int]) != (b["kinds"] as? [Int])
    }
}
