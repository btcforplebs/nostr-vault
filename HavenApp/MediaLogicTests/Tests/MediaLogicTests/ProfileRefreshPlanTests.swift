import XCTest
@testable import MediaLogic

final class ProfileRefreshPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDueOncePerDay() {
        XCTAssertTrue(ProfileRefreshPlan.isDue(lastCheck: nil, now: now), "never checked")
        XCTAssertFalse(ProfileRefreshPlan.isDue(lastCheck: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertTrue(ProfileRefreshPlan.isDue(lastCheck: now.addingTimeInterval(-24 * 3600), now: now))
    }

    func testSinceLooksBackAnHourPastTheLastCheck() {
        XCTAssertNil(ProfileRefreshPlan.since(lastCheck: nil), "the first check asks for every profile")
        XCTAssertEqual(ProfileRefreshPlan.since(lastCheck: now), 1_800_000_000 - 3600)
    }

    func testFiltersBatchAuthorsAndCarrySince() {
        let pubkeys = (0..<1018).map { String(format: "%064x", $0) } + ["", String(format: "%064x", 5)]
        let filters = ProfileRefreshPlan.filters(for: pubkeys, since: 42)
        XCTAssertEqual(filters.count, 5, "1,018 follows in batches of 250")
        let authors = filters.flatMap { $0["authors"] as? [String] ?? [] }
        XCTAssertEqual(authors.count, 1018, "duplicates and blanks dropped, nobody lost")
        XCTAssertEqual(Set(authors).count, 1018)
        for filter in filters {
            XCTAssertEqual(filter["kinds"] as? [Int], [0])
            XCTAssertEqual(filter["since"] as? Int64, 42)
            XCTAssertLessThanOrEqual((filter["authors"] as? [String])?.count ?? 0, 250)
        }
        XCTAssertNil(ProfileRefreshPlan.filters(for: ["a"], since: nil)[0]["since"], "no since on the first check")
        XCTAssertTrue(ProfileRefreshPlan.filters(for: [], since: 1).isEmpty)
    }
}
