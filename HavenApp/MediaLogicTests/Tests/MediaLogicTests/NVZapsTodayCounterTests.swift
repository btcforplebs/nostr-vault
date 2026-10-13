import XCTest
@testable import MediaLogic

/// The relay half of "Zaps today": what NVZapsTodayCounter keeps from a relay
/// answer. The relay, the signature check and the publisher check are stand-ins
/// here; the counter's own steps between them are the app's.
@MainActor
final class NVZapsTodayCounterTests: XCTestCase {
    private let wallet = String(repeating: "c", count: 64)
    private let impostor = String(repeating: "d", count: 64)
    private let relays = [URL(string: "wss://relay.test/inbox")!]
    private let now = Date()

    /// A fresh account per test: the counter keeps one count, shared by all.
    private func account() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func receipt(_ id: String, to me: String, from publisher: String? = nil,
                         signed: Bool = true) -> [String: Any] {
        ["id": id, "kind": 9735, "pubkey": publisher ?? wallet,
         "created_at": Int(now.timeIntervalSince1970), "tags": [["p", me]],
         "sig": signed ? "good" : "forged"]
    }

    /// Checks whose relay returns `events`, answering (EOSE) unless told not to.
    /// Signed means `sig == "good"`; only `wallet` may publish for anyone.
    private func checks(_ events: [[String: Any]], answers: Bool = true,
                        activeAccount: @escaping () -> String,
                        published: (() -> Void)? = nil) -> NVZapsTodayCounter.Checks {
        let wallet = wallet
        return NVZapsTodayCounter.Checks(
            query: { _, _, onAnswered in
                if answers { onAnswered() }
                return events
            },
            isSigned: { ($0["sig"] as? String) == "good" },
            isValidReceipt: { publisher, _ in publisher == wallet },
            activeAccount: activeAccount,
            publish: { published?() }
        )
    }

    private func count(_ me: String, _ checks: NVZapsTodayCounter.Checks) async -> Int? {
        await NVZapsTodayCounter.count(for: me, relays: relays, at: now, using: checks)
        return NVZapsTodayCounter.current(for: me)?.count
    }

    func testAForgedOrUnsignedReceiptDoesNotCount() async {
        let me = account()
        let events = [receipt("1", to: me), receipt("2", to: me, signed: false)]
        let counted = await count(me, checks(events, activeAccount: { me }))
        XCTAssertEqual(counted, 1)
    }

    func testAReceiptFromAPublisherThatCannotSpeakForYouDoesNotCount() async {
        let me = account()
        let events = [receipt("1", to: me), receipt("2", to: me, from: impostor)]
        let counted = await count(me, checks(events, activeAccount: { me }))
        XCTAssertEqual(counted, 1)
    }

    func testNoRelayAnswerLeavesTheLastCountAlone() async {
        let me = account()
        let first = await count(me, checks([receipt("1", to: me), receipt("2", to: me)],
                                           activeAccount: { me }))
        XCTAssertEqual(first, 2)

        var published = false
        let silent = await count(me, checks([], answers: false, activeAccount: { me },
                                            published: { published = true }))
        XCTAssertEqual(silent, 2, "no EOSE and no events must not reset the count")
        XCTAssertFalse(published)
    }

    func testAnEmptyAnswerIsZero() async {
        let me = account()
        _ = await count(me, checks([receipt("1", to: me)], activeAccount: { me }))
        let answeredEmpty = await count(me, checks([], activeAccount: { me }))
        XCTAssertEqual(answeredEmpty, 0)
    }

    func testACountForOneAccountNeverShowsForAnother() async {
        let me = account()
        let other = account()
        let counted = await count(me, checks([receipt("1", to: me)], activeAccount: { me }))
        XCTAssertEqual(counted, 1)
        XCTAssertNil(NVZapsTodayCounter.current(for: other))
    }

    func testACountFinishedAfterTheAccountChangedIsDropped() async {
        let me = account()
        let switchedTo = account()
        var published = false
        let counted = await count(me, checks([receipt("1", to: me)], activeAccount: { switchedTo },
                                             published: { published = true }))
        XCTAssertNil(counted)
        XCTAssertNil(NVZapsTodayCounter.current(for: switchedTo))
        XCTAssertFalse(published)
    }

    func testRepublishesOnlyWhenTheNumberChanged() async {
        let me = account()
        var publishes = 0
        let events = [receipt("1", to: me)]
        _ = await count(me, checks(events, activeAccount: { me }, published: { publishes += 1 }))
        _ = await count(me, checks(events, activeAccount: { me }, published: { publishes += 1 }))
        XCTAssertEqual(publishes, 1)
    }
}
