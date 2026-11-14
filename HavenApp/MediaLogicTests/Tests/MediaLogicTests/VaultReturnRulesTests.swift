import XCTest
@testable import MediaLogic

/// The Vault tab on return and on an account switch (Logen 2026-11-13: red
/// tab, rows injected piece by piece, followers first).
final class VaultReturnRulesTests: XCTestCase {
    // MARK: - One swap per refresh

    func testNotReadingShowsAtOnce() {
        XCTAssertTrue(VaultListSwap.publishes(refreshing: false, heldFor: nil))
    }

    func testReadingHoldsTheOldList() {
        XCTAssertFalse(VaultListSwap.publishes(refreshing: true, heldFor: nil))
        XCTAssertFalse(VaultListSwap.publishes(refreshing: true, heldFor: 1))
    }

    func testAStuckReadStopsHoldingAtTheCap() {
        XCTAssertTrue(VaultListSwap.publishes(refreshing: true, heldFor: VaultListSwap.cap))
    }

    // MARK: - Store read (VaultDirectRead)

    func testOnceTheStoreAnsweredOnlyItHoldsTheList() {
        // The socket tops up live after the store read: never holds the list.
        XCTAssertFalse(VaultDirectRead.reading(storeAnswered: true, storeReading: false, socketReading: true,
                                               booting: false, nothingYet: true))
        XCTAssertTrue(VaultDirectRead.reading(storeAnswered: true, storeReading: true, socketReading: false,
                                              booting: false, nothingYet: false))
    }

    func testBeforeTheStoreAnswersTheSocketRulesStand() {
        XCTAssertTrue(VaultDirectRead.reading(storeAnswered: false, storeReading: false, socketReading: true,
                                              booting: false, nothingYet: false))
        XCTAssertTrue(VaultDirectRead.reading(storeAnswered: false, storeReading: false, socketReading: false,
                                              booting: true, nothingYet: false))
        // Followers (from disk) never show alone.
        XCTAssertTrue(VaultDirectRead.reading(storeAnswered: false, storeReading: false, socketReading: false,
                                              booting: false, nothingYet: true))
        XCTAssertFalse(VaultDirectRead.reading(storeAnswered: false, storeReading: false, socketReading: false,
                                               booting: false, nothingYet: false))
    }

    /// Every store read takes the whole window (Logen 11-14): a note stored
    /// late, dated before the newest held, showed a notification but never
    /// a Vault row while later reads asked only for what was newer.
    func testStoreRereadsTheWholeWindowEveryTime() {
        let filters: [[String: Any]] = [["kinds": [1, 20], "limit": 400], ["kinds": [0, 3, 7], "limit": 200]]
        let first = VaultDirectRead.storeRead(filters, answeredBefore: false)
        XCTAssertEqual(first.after.map { $0["kinds"] as? [Int] }, [[3]])
        let again = VaultDirectRead.storeRead(filters, answeredBefore: true)
        XCTAssertEqual(again.first.map { $0["kinds"] as? [Int] }, [[1, 20], [0, 7]])
        XCTAssertTrue(again.first.allSatisfy { $0["since"] == nil })
        // The follower lists (most of the bytes) only on the first read; the
        // live socket brings new ones.
        XCTAssertTrue(again.after.isEmpty)
    }

    func testTheStoreReadAsksNoSince() throws {
        let direct = try vaultAppSource("HavenApp/Services/Nostr/NostrService+VaultDirectRead.swift")
        XCTAssertTrue(direct.contains("until: nil, since: nil)"))
    }

    func testSocketTopUpNeverStartsAheadOfNow() {
        // A note dated 5 minutes ahead must not hide notes made now.
        XCTAssertEqual(VaultDirectRead.socketSince(full: false, storeAnswered: true, remoteRelay: false, newest: 2_300, now: 2_000), 1_940)
    }

    func testANotificationReadsTheStore() throws {
        let capture = try vaultAppSource("HavenApp/Services/Relay/RelayProcessManager+OutputCapture.swift")
        let markers = try XCTUnwrap(capture.range(of: "LocalNotificationService.shared.handle(marker)"))
        let read = try XCTUnwrap(capture.range(of: "NostrService.shared.readVaultFromStore()", options: .backwards))
        XCTAssertLessThan(markers.lowerBound, read.lowerBound)
        XCTAssertTrue(capture.contains("if !batch.notifyMarkers.isEmpty"))
    }

    func testSocketOnlyTopsUpAfterTheStoreUnlessAMacRelayIsRead() {
        XCTAssertEqual(VaultDirectRead.socketSince(full: true, storeAnswered: true, remoteRelay: false, newest: 1_000, now: 2_000), 940)
        XCTAssertNil(VaultDirectRead.socketSince(full: true, storeAnswered: true, remoteRelay: true, newest: 1_000, now: 2_000))
        XCTAssertNil(VaultDirectRead.socketSince(full: true, storeAnswered: false, remoteRelay: false, newest: 1_000, now: 2_000))
        XCTAssertEqual(VaultDirectRead.socketSince(full: false, storeAnswered: false, remoteRelay: true, newest: 1_000, now: 2_000), 940)
    }

    func testStoreAnswerParsing() {
        let rows = VaultStoreAnswer.rows(Data(#"{"events":[{"id":"a","kind":1}]}"#.utf8))
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(VaultStoreAnswer.rows(Data(#"{"events":[]}"#.utf8))?.count, 0)
        XCTAssertNil(VaultStoreAnswer.rows(Data(#"{"events":null,"error":"vault read not ready"}"#.utf8)))
        XCTAssertNil(VaultStoreAnswer.rows(Data("not json".utf8)))
    }

    private struct Row: Decodable {
        let id: String
        let tags: [[String]]
    }

    func testStoreAnswerDecodesEvents() {
        let answer = #"{"events":[{"id":"a","pubkey":"p","created_at":5,"kind":1,"tags":[["p","q"]],"content":"hi","sig":"s"}]}"#
        let events = VaultStoreAnswer.events(Data(answer.utf8), as: Row.self)
        XCTAssertEqual(events?.map(\.id), ["a"])
        XCTAssertEqual(events?.first?.tags, [["p", "q"]])
        XCTAssertEqual(VaultStoreAnswer.events(Data(#"{"events":[]}"#.utf8), as: Row.self)?.count, 0)
        // Not ready: nil, so the chip reads over the socket instead.
        XCTAssertNil(VaultStoreAnswer.events(Data(#"{"events":null,"error":"vault read not ready"}"#.utf8), as: Row.self))
        XCTAssertNil(VaultStoreAnswer.events(Data("not json".utf8), as: Row.self))
    }

    // MARK: - One dot per account

    func testEachAccountKeepsItsOwnDot() {
        var ledger = VaultNewsAccounts<String>()
        // A has news; switch to B, never opened here: nothing new, nothing seen.
        var shown = ledger.switchAccount(from: "A", to: "B", modes: ["likes"], dmSeen: 2)
        XCTAssertEqual(shown.modes, [])
        XCTAssertEqual(shown.dmSeen, 0)
        // Back to A: its dot is still there.
        shown = ledger.switchAccount(from: "B", to: "A", modes: [], dmSeen: 0)
        XCTAssertEqual(shown.modes, ["likes"])
        XCTAssertEqual(shown.dmSeen, 2)
    }

    func testKeysIgnoreCase() {
        var ledger = VaultNewsAccounts<String>()
        _ = ledger.switchAccount(from: "AB", to: "cd", modes: ["zaps"], dmSeen: 1)
        XCTAssertEqual(ledger.switchAccount(from: "cd", to: "ab", modes: [], dmSeen: 0).modes, ["zaps"])
    }

    func testOnlyNewerThanTheLastVisitIsNews() {
        XCTAssertFalse(VaultNewsAccounts<String>.isNews(createdAt: [100, 200], lastVisit: 200),
                       "a catch-up of things already seen")
        XCTAssertTrue(VaultNewsAccounts<String>.isNews(createdAt: [100, 201], lastVisit: 200))
        XCTAssertTrue(VaultNewsAccounts<String>.isNews(createdAt: [5], lastVisit: nil), "never visited")
        XCTAssertFalse(VaultNewsAccounts<String>.isNews(createdAt: [], lastVisit: nil))
    }

    // MARK: - Wiring

    private static let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent(path), encoding: .utf8)
    }

    func testReturnFetchesOnlyWhatIsNew() throws {
        let scene = try source("HavenApp-iOS/SceneDelegate.swift")
        XCTAssertTrue(scene.contains("NostrService.shared.fetchNotes(from: urls, since: since)"))
        XCTAssertFalse(scene.contains("NostrService.shared.fetchNotes(from: urls)\n"))
        XCTAssertFalse(scene.contains("saveVaultSnapshot"))
        let read = try XCTUnwrap(scene.range(of: "NostrService.shared.readVaultFromStore()"))
        let socket = try XCTUnwrap(scene.range(of: "NostrService.shared.fetchNotes(from: urls, since: since)"))
        XCTAssertLessThan(read.lowerBound, socket.lowerBound)
    }

    func testTheVaultListPublishesThroughTheSwap() throws {
        let data = try source("HavenApp/Views/Vault/VaultDataProcessing.swift")
        let gate = try XCTUnwrap(data.range(of: "self.listSwapPublishes(owner: owner, eventCount: events.count)"))
        let publish = try XCTUnwrap(data.range(of: "self.displayActivity = shown"))
        XCTAssertLessThan(gate.lowerBound, publish.lowerBound)
        for path in ["HavenApp/Views/Vault/VaultView.swift", "HavenApp/Views/Vault/VaultView+Content.swift"] {
            let view = try source(path)
            XCTAssertTrue(view.contains("listSwapAccountSwitched()"), path)
            XCTAssertTrue(view.contains("listSwapReadChanged()"), path)
        }
    }

    func testAccountSwitchReadsTheNewAccountFromTheStore() throws {
        let conn = try source("HavenApp/Services/Nostr/NostrService+Connection.swift")
        let clear = try XCTUnwrap(conn.range(of: "events.removeAll()"))
        let read = try XCTUnwrap(conn.range(of: "readVaultFromStore()"))
        XCTAssertLessThan(clear.lowerBound, read.lowerBound)
        XCTAssertTrue(conn.contains("vaultStoreAnswered = \"\""))
        XCTAssertTrue(conn.contains("switchNewsDot(from: previous, to: activeHexPubkey)"))
        XCTAssertFalse(conn.contains("VaultSnapshot"))
    }

    func testTheStoreIsReadWhenTheEngineIsUpAndOnEveryRefresh() throws {
        let capture = try source("HavenApp/Services/Relay/RelayProcessManager+OutputCapture.swift")
        XCTAssertTrue(capture.contains("NostrService.shared.readVaultFromStore()"))
        // And right after the engine is called, not on the "ready" line.
        let start = try source("HavenApp/Services/Relay/RelayProcessManager+Start.swift")
        let call = try XCTUnwrap(start.range(of: "StartRelayC(0)"))
        let early = try XCTUnwrap(start.range(of: "NostrService.shared.readVaultFromStore()"))
        XCTAssertLessThan(call.lowerBound, early.lowerBound)
        let net = try source("HavenApp/Views/Vault/VaultNetworking.swift")
        let read = try XCTUnwrap(net.range(of: "nostrService.readVaultFromStore()"))
        let debounce = try XCTUnwrap(net.range(of: "refreshDebounceTask = Task"))
        XCTAssertLessThan(read.lowerBound, debounce.lowerBound)
        // Through the socket's own event path, so dot, media and live list see them.
        let direct = try source("HavenApp/Services/Nostr/NostrService+VaultDirectRead.swift")
        XCTAssertTrue(direct.contains("self.processEvent(row, from: local)"))
    }

    func testTheDotIsProposedNotLitByTheLogLine() throws {
        let capture = try source("HavenApp/Services/Relay/RelayProcessManager+OutputCapture.swift")
        XCTAssertTrue(capture.contains("proposeNews(landed)"))
        XCTAssertFalse(capture.contains("newActivityModes.formUnion(landed)"))
    }
}

final class VaultStorePassesTests: XCTestCase {
    func testFirstReadPutsFollowerListsInTheSecondPass() {
        let filters: [[String: Any]] = [
            ["kinds": [1, 20], "limit": 400],
            ["kinds": [0, 3, 7], "limit": 200, "#p": ["me"]],
            ["kinds": [3], "limit": 50],
        ]
        let passes = VaultDirectRead.storePasses(filters, split: true)
        XCTAssertEqual(passes.first.map { $0["kinds"] as? [Int] }, [[1, 20], [0, 7]])
        XCTAssertEqual(passes.first[1]["#p"] as? [String], ["me"])
        XCTAssertEqual(passes.first[1]["limit"] as? Int, 200)
        XCTAssertEqual(passes.after.map { $0["kinds"] as? [Int] }, [[3], [3]])
        XCTAssertEqual(passes.after[0]["#p"] as? [String], ["me"])
        XCTAssertEqual(passes.after[1]["limit"] as? Int, 50)
    }

    func testLaterReadsStayOnePass() {
        let filters: [[String: Any]] = [["kinds": [0, 3, 7], "since": 5]]
        let passes = VaultDirectRead.storePasses(filters, split: false)
        XCTAssertEqual(passes.first.count, 1)
        XCTAssertEqual(passes.first[0]["kinds"] as? [Int], [0, 3, 7])
        XCTAssertTrue(passes.after.isEmpty)
    }

    func testNotReadyRetriesOnlyWhileStartingAndBounded() {
        XCTAssertTrue(VaultDirectRead.retriesNotReady(booting: true, waited: 0.1))
        XCTAssertFalse(VaultDirectRead.retriesNotReady(booting: false, waited: 0.1))
        XCTAssertFalse(VaultDirectRead.retriesNotReady(booting: true, waited: VaultDirectRead.notReadyGiveUp))
    }
}

/// A file of the app, for the wiring checks.
private func vaultAppSource(_ path: String) throws -> String {
    let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: app.appendingPathComponent(path), encoding: .utf8)
}
