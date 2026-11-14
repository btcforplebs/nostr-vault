import XCTest
@testable import MediaLogic

/// The one safe list save (ListVersionSave, twin of Android ListVersionSave.kt): the old version is kept in the
/// vault first, the new one is stored in the vault before it goes to relays, and nothing is signed or sent when the
/// vault didn't keep the old copy (RESEARCH/NV_EMOJI_LIST_HISTORY_AUDIT.md, Logen 2026-11-14).
final class ListVersionSaveTests: XCTestCase {

    private struct Event: ListVersionSaveEvent, Equatable {
        let id: String
        let pubkey: String
        let created_at: Int64
    }

    private final class Fake: @unchecked Sendable {
        var account = "me"
        var newest: Result<Event?, ListVersionSave.Failure> = .success(Event(id: "old", pubkey: "me", created_at: 100))
        var keeps = true
        var stores = true
        var signer = "me"
        var log: [String] = []

        var steps: ListVersionSave.Steps<Event> {
            .init(activeAccount: { self.account },
                  newest: { self.newest },
                  keepUndoCopy: { self.log.append("keep \($0.id)"); return self.keeps },
                  sign: { _, _, _, notBefore in
                      self.log.append("sign \(notBefore)")
                      return Event(id: "new", pubkey: self.signer, created_at: notBefore)
                  },
                  store: { self.log.append("store \($0.id)"); return self.stores },
                  send: { self.log.append("send \($0.id)") })
        }
    }

    private func save(_ fake: Fake, shown: String?? = nil) async -> ListVersionSave.Outcome<Event> {
        await ListVersionSave.save(fake.steps, pubkey: "me", kind: 10030, shownId: shown, verb: "change", now: 50) { current in
            .ready(tags: (current == nil ? [] : [["a", "30030:x:y"]]), content: "")
        }
    }

    func testKeepsTheOldVersionThenStoresThenSends() async {
        let fake = Fake()
        let outcome = await save(fake)
        XCTAssertEqual(fake.log, ["keep old", "sign 101", "store new", "send new"])
        guard case .saved(let event) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(event.id, "new")
    }

    func testStopsWhenTheVaultDidNotKeepTheOldCopy() async {
        let fake = Fake()
        fake.keeps = false
        let outcome = await save(fake)
        XCTAssertEqual(fake.log, ["keep old"], "nothing signed, stored or sent")
        guard case .refused(let message, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "Your vault couldn't keep a copy of your newest emoji list, so the change couldn't be undone. Nothing was changed.")
    }

    func testNothingGoesToRelaysWhenTheVaultRefusesTheNewVersion() async {
        let fake = Fake()
        fake.stores = false
        let outcome = await save(fake)
        XCTAssertEqual(fake.log, ["keep old", "sign 101", "store new"])
        guard case .refused(let message, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "Your vault refused the changed emoji list. Nothing was sent to your relays.")
    }

    func testNoListYetHasNothingToKeep() async {
        let fake = Fake()
        fake.newest = .success(nil)
        _ = await save(fake)
        XCTAssertEqual(fake.log.count, 3)
        XCTAssertFalse(fake.log.contains { $0.hasPrefix("keep") })
        XCTAssertEqual(fake.log.suffix(2), ["store new", "send new"])
    }

    func testAnUnknownNewestListChangesNothing() async {
        let fake = Fake()
        fake.newest = .failure(.init(message: "Not enough of your relays answered."))
        let outcome = await save(fake)
        XCTAssertEqual(fake.log, [])
        guard case .refused(let message, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(message, "Not enough of your relays answered.")
    }

    func testAShownListThatChangedIsRefused() async {
        let fake = Fake()
        let outcome = await save(fake, shown: .some("older"))
        XCTAssertEqual(fake.log, [])
        guard case .refused(_, let changed) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(changed)
    }

    func testNoShownListMeansNoCheck() async {
        let fake = Fake()
        guard case .saved = await save(fake, shown: nil) else { return XCTFail() }
    }

    func testUnchangedListSignsNothing() async {
        let fake = Fake()
        let outcome = await ListVersionSave.save(fake.steps, pubkey: "me", kind: 10030, shownId: nil, verb: "change") { _ in .unchanged }
        XCTAssertEqual(fake.log, [], "no new version, so no undo copy is needed either")
        guard case .unchanged(let current) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(current?.id, "old")
    }

    func testAnotherSignerOrAnAccountSwitchSendsNothing() async {
        let other = Fake()
        other.signer = "them"
        guard case .refused = await save(other) else { return XCTFail() }
        XCTAssertFalse(other.log.contains { $0.hasPrefix("store") || $0.hasPrefix("send") })

        let switched = Fake()
        let steps = switched.steps
        var calls = 0
        let flaky = ListVersionSave.Steps<Event>(
            activeAccount: { calls += 1; return calls > 1 ? "else" : "me" },
            newest: steps.newest, keepUndoCopy: steps.keepUndoCopy, sign: steps.sign, store: steps.store, send: steps.send)
        let outcome = await ListVersionSave.save(flaky, pubkey: "me", kind: 10030, shownId: nil, verb: "change") { _ in
            .ready(tags: [], content: "")
        }
        guard case .refused = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(switched.log.contains { $0.hasPrefix("send") })
    }

    func testAnEmojiSetIsNamedInMessages() async {
        let fake = Fake()
        fake.keeps = false
        let outcome = await ListVersionSave.save(fake.steps, pubkey: "me", kind: 30030, shownId: nil, verb: "save") { _ in
            .ready(tags: [], content: "")
        }
        guard case .refused(let message, _) = outcome else { return XCTFail() }
        XCTAssertEqual(message, "Your vault couldn't keep a copy of your newest emoji set, so the save couldn't be undone. Nothing was changed.")
    }
}
