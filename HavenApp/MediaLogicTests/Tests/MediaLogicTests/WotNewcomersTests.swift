import XCTest
@testable import MediaLogic

/// Your space's WoT mini "New in your web" (twin of wot-mini.js newInWeb).
final class WotNewcomersTests: XCTestCase {
    private func pk(_ n: Int) -> String { String(format: "%08x", n) + String(repeating: "0", count: 56) }

    func testFirstLookNotesEveryoneAndShowsNoOne() {
        let kept = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: nil, now: 100)
        XCTAssertTrue(kept.fresh.isEmpty)
        XCTAssertEqual(kept.known.count, 2)
    }

    func testSomeoneNewShowsForAWeekWhileVouched() {
        var kept = WotNewcomers.update(vouched: [pk(1)], kept: nil, now: 0)
        kept = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: kept, now: 10)
        XCTAssertEqual(kept.fresh.map(\.pubkey), [pk(2)])
        // Still new six days later, gone after seven.
        XCTAssertEqual(WotNewcomers.update(vouched: [pk(1), pk(2)], kept: kept, now: 10 + 6 * 86400).fresh.map(\.pubkey), [pk(2)])
        XCTAssertTrue(WotNewcomers.update(vouched: [pk(1), pk(2)], kept: kept, now: 10 + 7 * 86400).fresh.isEmpty)
    }

    func testMutedPeopleAreNeverOfferedNorNewlyNotedAndDropOutOnceMuted() {
        let muted: Set<String> = [pk(2)]
        let first = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: nil, now: 1000, muted: muted)
        XCTAssertTrue(first.fresh.isEmpty)
        XCTAssertEqual(first.known, [String(pk(1).prefix(8))], "a muted person isn't noted on a first look")
        let r = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: first, now: 2000)
        XCTAssertEqual(r.fresh.map(\.pubkey), [pk(2)])
        let nowMuted = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: r, now: 3000, muted: muted)
        XCTAssertTrue(nowMuted.fresh.isEmpty, "muted after arriving: no longer new")
        XCTAssertTrue(WotNewcomers.update(vouched: [pk(1), pk(2)], kept: nowMuted, now: 4000).fresh.isEmpty,
                      "once known they don't come back as new after an unmute")
    }

    func testSomeoneWhoDropsOutAndComesBackIsNotNewAgain() {
        var kept = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: nil, now: 0)
        kept = WotNewcomers.update(vouched: [pk(1)], kept: kept, now: 10)
        kept = WotNewcomers.update(vouched: [pk(1), pk(2)], kept: kept, now: 20)
        XCTAssertTrue(kept.fresh.isEmpty)
    }

    func testKeepsAtMostForty() {
        var kept = WotNewcomers.update(vouched: [], kept: nil, now: 0)
        kept = WotNewcomers.update(vouched: (1...50).map(pk), kept: kept, now: 1)
        XCTAssertEqual(kept.fresh.count, WotNewcomers.kept)
    }
}
