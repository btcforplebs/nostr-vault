import XCTest
@testable import MediaLogic

/// The dashboard's GM tile (twin of Android GreetingCountsTest).
final class GreetingCountsTests: XCTestCase {
    private let me = String(repeating: "aa", count: 32)
    private let other = String(repeating: "bb", count: 32)

    private func note(_ id: String, _ content: String, _ at: Int64, kind: Int = 1, pubkey: String? = nil) -> GreetingCounts.Note {
        .init(id: id, pubkey: pubkey ?? me, kind: kind, createdAt: at, content: content)
    }

    func testPlainGreetingsCountAsGM() {
        for s in ["gm", "GM", "gm!", "Gm.", "Good Morning", "good morning!!", "GOOD MORNING", "gmgm", "gmmm", "gm ☕", "  gm\n"] {
            XCTAssertEqual(GreetingCounts.greetings(s), [.gm], s)
        }
    }

    func testPuraVidaAndPVGetTheirOwnGreeting() {
        for s in ["Pura Vida", "pura vida!", "PV", "pv 🌴"] {
            XCTAssertEqual(GreetingCounts.greetings(s), [.puraVida], s)
        }
        XCTAssertEqual(GreetingCounts.greetings("GM, pura vida"), [.gm, .puraVida])
    }

    func testAGreetingWithAFewWordsAPhotoOrATagStillCounts() {
        for s in ["gm nostr", "Good morning everyone, frens", "gm https://image.example/a.jpg", "#gm gm", "gm nostr:npub1xyz", "gm #coffee"] {
            XCTAssertEqual(GreetingCounts.greetings(s), [.gm], s)
        }
    }

    func testANoteThatOnlyContainsGMDoesNotCount() {
        for s in ["gm, today we ship the new relay build", "I said gm to everyone at the meetup",
                  "the gm of the hotel was great tonight", "good", "morning", "programming", "pvc pipes", "",
                  "https://example.com/gm", "#gm"] {
            XCTAssertEqual(GreetingCounts.greetings(s), [], s)
        }
    }

    func testCountsOnlyMyKind1NotesTodayAndAllTimeOncePerId() {
        let today: Int64 = 1_000_000
        let notes = [
            note("1", "gm", today + 10),
            note("2", "GM!", today - 10),
            note("2", "GM!", today - 10),
            note("3", "Pura Vida", today + 5),
            note("4", "pv", today - 100),
            note("5", "gm pura vida", today - 200),
            note("6", "gm, here is a long update about the release", today + 1),
            note("7", "gm", today + 1, pubkey: other),
            note("8", "gm", today + 1, kind: 7),
        ]
        XCTAssertEqual(GreetingCounts.count(notes, author: me, todayStart: today),
                       .init(gmToday: 1, gmAll: 3, pvToday: 1, pvAll: 3))
    }

    func testReadsEveryPageBackWithUntil() async {
        let all = [note("e", "gm", 50), note("d", "gm", 40), note("c", "gm", 30), note("b", "gm", 30), note("a", "gm", 10)]
        var filters: [[String: Any]] = []
        let got = await GreetingCounts.readAll(author: me, pageSize: 2, maxPages: 10) { filter in
            filters.append(filter)
            let until = filter["until"] as? Int64 ?? .max
            return Array(all.filter { $0.createdAt <= until }.prefix(2))
        }
        XCTAssertEqual(got?.map(\.id), ["e", "d", "c", "b", "a"])
        XCTAssertEqual(filters.first?["kinds"] as? [Int], [1])
        XCTAssertEqual(filters.first?["authors"] as? [String], [me])
        XCTAssertNil(filters.first?["until"])
    }

    func testNoStoreAnswerMeansNoCounts() async {
        let got = await GreetingCounts.readAll(author: me, pageSize: 2, maxPages: 3) { _ in nil }
        XCTAssertNil(got)
    }

    func testLabelReadsGMThenPV() {
        XCTAssertEqual(GreetingCounts.label(gm: 12, pv: 3), "GM 12 · PV 3")
    }
}
