import XCTest
@testable import MediaLogic

final class SearchFilterTests: XCTestCase {

    private let me = "aa"
    private let friend = "bb"
    private let stranger = "cc"
    private var follows: Set<String> { [friend] }

    func testDefaultIsOffAndHasNoSummary() {
        XCTAssertFalse(SearchFilter.all.isActive)
        XCTAssertNil(SearchFilter.all.summary)
        XCTAssertEqual(SearchFilter.all.accessibilitySummary, "No filter")
    }

    func testEveryoneLetsEveryAuthorThrough() {
        let scope = SearchFilter.all
        XCTAssertTrue(scope.allowsAuthor(me, own: me, follows: follows))
        XCTAssertTrue(scope.allowsAuthor(friend, own: me, follows: follows))
        XCTAssertTrue(scope.allowsAuthor(stranger, own: me, follows: follows))
    }

    func testFollowsKeepsOnlyFollowedAuthors() {
        let scope = SearchFilter(who: .follows)
        XCTAssertTrue(scope.allowsAuthor(friend, own: me, follows: follows))
        XCTAssertFalse(scope.allowsAuthor(me, own: me, follows: follows))
        XCTAssertFalse(scope.allowsAuthor(stranger, own: me, follows: follows))
    }

    func testYouKeepsOnlyTheOwnAccount() {
        let scope = SearchFilter(who: .you)
        XCTAssertTrue(scope.allowsAuthor(me, own: me, follows: follows))
        XCTAssertFalse(scope.allowsAuthor(friend, own: me, follows: follows))
    }

    /// Browse-only installs have no account; "You" must then show nothing,
    /// not fall open to everyone.
    func testYouWithNoAccountMatchesNothing() {
        let scope = SearchFilter(who: .you)
        XCTAssertFalse(scope.allowsAuthor(me, own: nil, follows: follows))
        XCTAssertFalse(scope.allowsAuthor(me, own: "", follows: follows))
    }

    func testAnyTimeHasNoWindow() {
        let scope = SearchFilter.all
        XCTAssertTrue(scope.allowsDate(.distantPast, now: Date()))
    }

    func testWhenWindowsAreInclusiveAtTheEdge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = SearchFilter(when: .day)
        XCTAssertTrue(day.allowsDate(now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertFalse(day.allowsDate(now.addingTimeInterval(-24 * 3600 - 1), now: now))

        let week = SearchFilter(when: .week)
        XCTAssertTrue(week.allowsDate(now.addingTimeInterval(-6 * 24 * 3600), now: now))
        XCTAssertFalse(week.allowsDate(now.addingTimeInterval(-8 * 24 * 3600), now: now))

        let month = SearchFilter(when: .month)
        XCTAssertTrue(month.allowsDate(now.addingTimeInterval(-29 * 24 * 3600), now: now))
        XCTAssertFalse(month.allowsDate(now.addingTimeInterval(-31 * 24 * 3600), now: now))
    }

    func testFutureDatedNotesPassEveryWindow() {
        let now = Date()
        for when in SearchFilter.When.allCases {
            XCTAssertTrue(SearchFilter(when: when).allowsDate(now.addingTimeInterval(60), now: now), "\(when)")
        }
    }

    func testSummaryNamesOnlyWhatIsOn() {
        XCTAssertEqual(SearchFilter(who: .follows).summary, "Follows")
        XCTAssertEqual(SearchFilter(when: .week).summary, "Week")
        XCTAssertEqual(SearchFilter(who: .you, when: .day).summary, "You · 24 h")
        XCTAssertEqual(SearchFilter(who: .you, when: .day).accessibilitySummary, "You, Last 24 hours")
    }
}
