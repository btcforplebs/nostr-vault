import XCTest
@testable import MediaLogic

/// The profile's hop line: true hops at any distance, and who you follow
/// follows them. Android twin: `ProfileHopTextTest.kt`.
final class ProfileHopTextTests: XCTestCase {
    private static func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private func pk(_ c: Character) -> String { Self.pk(c) }
    private let me = pk("a"), them = pk("t")
    private let alice = pk("1"), bob = pk("2"), carol = pk("3"), dan = pk("4"), eve = pk("5")
    private var names: [String: String] { [alice: "Alice", bob: "Bob", carol: "Carol", dan: "Dan", eve: "Eve"] }
    private typealias Person = TrustRankCopy.Person

    private func line(_ path: TrustPath?, _ rank: Person? = nil, who: String? = nil) -> String? {
        ProfileHopText.line(pubkey: who ?? them, me: me, path: path, rank: rank) { self.names[$0] ?? "?" }
    }

    private func bridged(_ all: [String], hasMore: Bool? = nil, exact: Bool = true) -> TrustPath {
        TrustPath(reach: .bridged, bridges: Array(all.prefix(TrustPath.shownBridges)),
                  hasMore: hasMore ?? (all.count > TrustPath.shownBridges), all: all, complete: exact)
    }

    private func path(_ reach: TrustPath.Reach?) -> TrustPath? {
        reach.map { TrustPath(reach: $0, bridges: [], hasMore: false) }
    }

    private func hex(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "%064x", $0) } }

    func testAFollowIsOneHop() {
        XCTAssertEqual(line(path(.follow), Person(score: 99, hop: 1)), "1 hop · you follow them")
    }

    func testTwoHopsNamesWhoYouFollowFollowsThem() {
        XCTAssertEqual(line(bridged([alice])), "2 hops · followed by Alice")
        XCTAssertEqual(line(bridged([alice, bob])), "2 hops · followed by Alice and Bob")
        XCTAssertEqual(line(bridged([alice, bob, carol, dan, eve])), "2 hops · followed by Alice, Bob and 3 more")
        // The links file knows every bridge: an exact count past the five shown.
        XCTAssertEqual(line(bridged([alice, bob] + hex(10...20))), "2 hops · followed by Alice, Bob and 11 more")
    }

    func testRelaysGiveAFloorNotACountSoNoNumber() {
        // Several relays can each send six lists: ten found, more may exist.
        XCTAssertEqual(line(bridged([alice, bob] + hex(10...17), hasMore: true, exact: false)),
                       "2 hops · followed by Alice, Bob and more")
        XCTAssertEqual(line(bridged([alice, bob, carol], exact: false)), "2 hops · followed by Alice, Bob and more")
        XCTAssertEqual(line(bridged([alice, bob], exact: false)), "2 hops · followed by Alice and Bob")
        // The links file with exactly six: an exact count.
        XCTAssertEqual(line(bridged([alice, bob, carol, dan, eve, pk("6")])), "2 hops · followed by Alice, Bob and 4 more")
    }

    func testPastTwoHopsTheHavensRingAtAnyDistanceUpToSix() {
        for hop in 3...6 {
            for reach in [TrustPath.Reach.web, .outside, .unknown, nil] {
                XCTAssertEqual(line(path(reach), Person(score: 50, hop: hop)), "\(hop) hops")
            }
        }
    }

    func testTheNearRingsComeFromYourWebNeverFromADayOldFile() {
        // Followed since the Haven ranked: a follow, whatever the file says.
        XCTAssertEqual(line(path(.follow), Person(score: 50, hop: 3)), "1 hop · you follow them")
        XCTAssertEqual(line(bridged([alice]), Person(score: 50, hop: 4)), "2 hops · followed by Alice")
        // Unfollowed since: the file's ring 1 is never "you follow them".
        for reach in [TrustPath.Reach.web, .outside, .unknown, nil] {
            XCTAssertNil(line(path(reach), Person(score: 99, hop: 1)), "\(String(describing: reach))")
        }
        // Ring 2 from the file, no names, only when the path can't say; outside your web, nothing.
        XCTAssertEqual(line(path(.web), Person(score: 70, hop: 2)), "2 hops")
        XCTAssertEqual(line(nil, Person(score: 70, hop: 2)), "2 hops")
        XCTAssertNil(line(path(.outside), Person(score: 70, hop: 2)))
    }

    func testNoLineForYouOrForSomeoneNobodyCanPlace() {
        XCTAssertNil(line(nil, Person(score: 99, hop: 1), who: me))
        XCTAssertNil(line(nil, Person(score: 99, hop: 1), who: me.uppercased()))
        XCTAssertNil(line(path(.you)))
        XCTAssertNil(line(nil))
        XCTAssertNil(line(path(.outside)))
        XCTAssertNil(line(path(.web)))
        XCTAssertNil(line(path(.unknown)))
    }
}
