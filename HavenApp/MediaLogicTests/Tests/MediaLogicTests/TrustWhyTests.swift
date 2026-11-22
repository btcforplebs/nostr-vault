import XCTest
@testable import MediaLogic

/// The "why?" sheet: score, ring, and who you follow follows them, highest
/// first. No mute rows (Q3 open). Android twin: `TrustWhyTest.kt`.
final class TrustWhyTests: XCTestCase {
    private typealias Person = TrustRankCopy.Person
    private static func pk(_ c: Character) -> String { String(repeating: c, count: 64) }
    private let me = pk("a"), them = pk("t")
    private let hi = pk("1"), mid = pk("2"), unknown = pk("3")

    private func copy(_ people: [String: Person]) -> TrustRankCopy {
        TrustRankCopy(account: me, builtAt: 1_795_300_000, maxHop: 4, viewBar: 55, floor: 45, people: people)
    }

    private var ranked: TrustRankCopy {
        copy([them: Person(score: 61.4, hop: 2), hi: Person(score: 99, hop: 1), mid: Person(score: 80, hop: 1)])
    }

    private func bridged(_ all: [String], exact: Bool = true) -> TrustPath {
        TrustPath(reach: .bridged, bridges: Array(all.prefix(5)), hasMore: all.count > 5, all: all, complete: exact)
    }

    private func path(_ reach: TrustPath.Reach) -> TrustPath { TrustPath(reach: reach, bridges: [], hasMore: false) }

    func testScoreRingAndFollowersHighestScoreFirstUnscoredLast() throws {
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([unknown, mid, hi])))
        XCTAssertEqual(why.score, 61)
        XCTAssertEqual(why.hop, 2)
        XCTAssertEqual(why.bar, 55)
        XCTAssertTrue(why.overBar)
        XCTAssertEqual(why.followers, [.init(pubkey: hi, score: 99), .init(pubkey: mid, score: 80), .init(pubkey: unknown, score: nil)])
        XCTAssertEqual(TrustWhyText.headline(why), "Score 61 of 100")
        XCTAssertEqual(TrustWhyText.place(why), "2 hops from you · at or over the 55 discovery starts at")
        XCTAssertEqual(TrustWhyText.followersTitle(why), "3 people you follow follow them")
    }

    func testARelayCountIsAFloor() throws {
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([hi, mid], exact: false)))
        XCTAssertEqual(TrustWhyText.followersTitle(why), "At least 2 people you follow follow them")
    }

    func testFarOutUnderTheBarNoOneYouFollowFollowsThem() throws {
        let far = copy([them: Person(score: 47.2, hop: 4)])
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: far, path: path(.outside)))
        XCTAssertEqual(why.hop, 4)
        XCTAssertEqual(TrustWhyText.place(why), "4 hops from you · under the 55 discovery starts at")
        XCTAssertEqual(TrustWhyText.followersTitle(why), "No one you follow follows them")
    }

    func testARelayFloorOfOneIsAFloorToo() throws {
        let floor = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([hi], exact: false)))
        XCTAssertEqual(TrustWhyText.followersTitle(floor), "At least 1 person you follow follows them")
        let exact = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([hi])))
        XCTAssertEqual(TrustWhyText.followersTitle(exact), "1 person you follow follows them")
    }

    func testNoOneIsSaidOnlyWhenThePathSaysOutside() throws {
        // Still tracing: the file's ring 2 shows, the follower line waits.
        XCTAssertEqual(TrustWhyText.followersTitle(try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: nil))),
                       "Checking…")
        // In the graph but no bridge seen, or no graph yet: no claim either way.
        XCTAssertNil(TrustWhyText.followersTitle(try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: path(.web)))))
        XCTAssertNil(TrustWhyText.followersTitle(try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: path(.unknown)))))
        // A follow whose own follows aren't known.
        let follow = copy([them: Person(score: 70, hop: 1)])
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: follow, path: path(.follow)))
        XCTAssertEqual(why.hop, 1)
        XCTAssertNil(TrustWhyText.followersTitle(why))
    }

    func testLongListsAreCutAndCounted() throws {
        let many = (100..<(100 + TrustWhy.shown + 3)).map { String(format: "%064x", $0) }
        XCTAssertEqual(TrustWhyText.more(try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged(many)))),
                       "and 3 more")
        XCTAssertNil(TrustWhyText.more(try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([hi])))))
    }

    func testNoSheetWithoutAScoreForYouOrWhenTheWebSaysTheyAreOutsideTheFilesNearRing() {
        XCTAssertNil(TrustWhy.of(pubkey: them, me: me, copy: nil, path: bridged([hi])))
        XCTAssertNil(TrustWhy.of(pubkey: Self.pk("z"), me: me, copy: ranked, path: nil))
        XCTAssertNil(TrustWhy.of(pubkey: me, me: me, copy: copy([me: Person(score: 99, hop: 1)]), path: nil))
        // The file says ring 2, the path (live) says outside: no claim.
        XCTAssertNil(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: path(.outside)))
    }

    func testHalvesRoundUpAsOnAndroid() throws {
        let half = copy([them: Person(score: 54.5, hop: 3)])
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: half, path: nil))
        XCTAssertEqual(why.score, 55)
        XCTAssertTrue(why.overBar)
    }

    func testAHugeBarCannotCrashTheSheet() throws {
        for bar in [1e300, -1e300, .infinity] {
            let odd = TrustRankCopy(account: me, builtAt: 1, maxHop: 4, viewBar: bar, floor: 0,
                                    people: [them: Person(score: 50, hop: 3)])
            let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: odd, path: nil))
            XCTAssertTrue((0...100).contains(why.bar))
        }
    }

        func testTheSheetHasNoMuteWords() throws {
        let why = try XCTUnwrap(TrustWhy.of(pubkey: them, me: me, copy: ranked, path: bridged([hi])))
        let words = [TrustWhyText.headline(why), TrustWhyText.place(why), TrustWhyText.followersTitle(why), TrustWhyText.how]
            .compactMap { $0 }
        XCTAssertFalse(words.contains { $0.localizedCaseInsensitiveContains("mute") })
    }
}
