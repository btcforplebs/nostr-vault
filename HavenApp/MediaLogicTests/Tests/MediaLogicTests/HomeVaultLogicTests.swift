import XCTest
@testable import MediaLogic

/// The rules the iOS home vault sender runs on.
final class HomeVaultLogicTests: XCTestCase {
    private let npub = "npub1" + String(repeating: "q", count: 58)
    private let other = "npub1" + String(repeating: "p", count: 58)

    func testOnlyTheExactMeshEntryFormIsAVault() {
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)/"), npub)
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)"), "no trailing slash")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)q"), "no slash, one more bech32 char")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub):80/"), "a port")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)/evil"), "a path")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://npub1short/"), "not an npub")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://npub1" + String(repeating: "b", count: 58) + "/"), "b is not bech32")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "https://blossom.primal.net/"))
    }

    func testChoicesSkipThisPhoneAndDuplicates() {
        let list = ["https://blossom.band/", "fipsmesh://\(npub)/", "fipsmesh://\(other)/", "fipsmesh://\(npub)/"]
        XCTAssertEqual(HomeVaultLogic.meshEntries(serverList: list, excluding: nil), [npub, other])
        XCTAssertEqual(HomeVaultLogic.meshEntries(serverList: list, excluding: npub), [other])
    }

    func testMediaQueuesAheadOfNotesSoANoteNeverLandsFirst() {
        func item(_ kind: HomeVaultItem.Kind, _ id: String) -> HomeVaultItem {
            HomeVaultItem(kind: kind, id: id, ownerHex: "aa", eventJSON: nil, contentType: nil, added: Date(), attempts: 0, notBefore: nil)
        }
        let queue = [item(.blob, "b1"), item(.event, "e1"), item(.event, "e2")]
        XCTAssertEqual(HomeVaultLogic.insertionIndex(for: .blob, in: queue), 1)
        XCTAssertNil(HomeVaultLogic.insertionIndex(for: .event, in: queue), "notes go last")
        XCTAssertNil(HomeVaultLogic.insertionIndex(for: .blob, in: [item(.blob, "b1")]), "no notes waiting: append")
    }

    func testTheWebsocketKeepsTheTokenPath() {
        let base = URL(string: "http://127.0.0.1:41234/0123456789abcdef0123456789abcdef")!
        XCTAssertEqual(HomeVaultLogic.websocketURL(base: base)?.absoluteString,
                       "ws://127.0.0.1:41234/0123456789abcdef0123456789abcdef")
    }

    func testOkAnswers() {
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",true,""]"#, id: "abc"), .sent)
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"duplicate: have it"]"#, id: "abc"), .sent)
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"restricted: the mesh accepts only the owner's own events"]"#, id: "abc"),
                       .rejected("restricted: the mesh accepts only the owner's own events"), "the door's final no")
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"auth-required: x"]"#, id: "abc"), .unreachable("auth-required: x"))
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"rate-limited: slow"]"#, id: "abc"), .unreachable("rate-limited: slow"))
        XCTAssertNil(HomeVaultLogic.okResult(#"["OK","other",true,""]"#, id: "abc"), "someone else's OK")
        XCTAssertNil(HomeVaultLogic.okResult(#"["NOTICE","hi"]"#, id: "abc"))
        XCTAssertNil(HomeVaultLogic.okResult("not json", id: "abc"))
    }

    func testUploadStatuses() {
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 200), .sent)
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 201), .sent)
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 403), .rejected("HTTP 403"), "not the owner: retrying won't help")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 413), .rejected("HTTP 413"), "over the door's 256 MB")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 411), .rejected("HTTP 411"))
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 429), .unreachable("HTTP 429"), "rate limit is about now")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 409), .unreachable("HTTP 409"), "a spent auth: sign a fresh one")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 404), .unreachable("HTTP 404"), "a kiosk without the upload door keeps the blob queued")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 502), .unreachable("HTTP 502"))
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 0), .unreachable("HTTP 0"))
    }

    func testQueueSurvivesARoundTrip() throws {
        let item = HomeVaultItem(kind: .event, id: "e1", ownerHex: "aa", eventJSON: #"{"id":"e1"}"#, contentType: nil,
                                 added: Date(timeIntervalSince1970: 1_000), attempts: 2, notBefore: Date(timeIntervalSince1970: 2_000))
        let back = try JSONDecoder().decode([HomeVaultItem].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual(back, [item])
    }
}

/// Merging the owner's 10063 across phones (merge, never replace).
final class ServerListMergeTests: XCTestCase {
    private let kiosk = "npub1" + String(repeating: "q", count: 58)
    private let me = "npub1" + String(repeating: "p", count: 58)
    private let third = "npub1" + String(repeating: "z", count: 58)
    private let fourth = "npub1" + String(repeating: "r", count: 58)
    private func mesh(_ n: String) -> String { "fipsmesh://\(n)/" }

    func testPublicServersComeBeforeMeshEntries() {
        // NIP-F1 order (Tao): a sender keeps the kiosk entry, after the public servers.
        let existing = [mesh(kiosk), "https://a.example/"]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/", mesh(kiosk)])
    }

    func testOtherMeshEntriesKeepTheirOrder() {
        let existing = ["https://a.example/", mesh(third), mesh(kiosk)]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/", mesh(third), mesh(kiosk)])
    }

    func testOnlyServersThisPhoneManagedAreRemoved() {
        // b was ours and is gone from config; c is another phone's.
        let existing = ["https://a.example/", "https://b.example/", "https://c.example/"]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example"],
                                                 previouslyManaged: ["https://a.example/", "https://b.example/"],
                                                 ownMeshNpub: nil, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example", "https://c.example/"])
    }

    func testThisPhonesMeshEntryOnlyWhileSharingAndLast() {
        let existing = [mesh(me), "https://a.example/", mesh(kiosk), "https://other-phone.example/"]
        let sharing = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                     ownMeshNpub: me, shareOwnMesh: true)
        XCTAssertEqual(sharing, ["https://a.example/", "https://other-phone.example/", mesh(kiosk), mesh(me)])
        let stopped = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                     ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(stopped, ["https://a.example/", "https://other-phone.example/", mesh(kiosk)])
    }

    func testAWithdrawnKioskEntryIsNotPutBack() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/"])
    }

    func testASenderListsItsHomeVaultAfterOtherMeshEntries() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/", mesh(third)],
                                                 current: ["https://a.example/", mesh(kiosk)], previouslyManaged: [],
                                                 ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/", mesh(third), mesh(kiosk)])
    }

    func testAChangedHomeVaultDropsTheOldOneOnly() {
        // This phone listed kiosk before; now third. Another phone's other entry stays.
        let existing = ["https://a.example/", mesh(kiosk), mesh(fourth)]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/", mesh(third)],
                                                 previouslyManaged: ["https://a.example/", mesh(kiosk)],
                                                 ownMeshNpub: me, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/", mesh(fourth), mesh(third)])
    }

    func testPastedAndScannedMeshAddresses() {
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromInput: kiosk), kiosk)
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromInput: " nostr:\(kiosk)\n"), kiosk)
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromInput: "fipsmesh://\(kiosk)/"), kiosk)
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromInput: "fipsmesh://\(kiosk)"), kiosk)
        XCTAssertNil(HomeVaultLogic.meshNpub(fromInput: "https://\(kiosk)/"))
        XCTAssertNil(HomeVaultLogic.meshNpub(fromInput: "npub1short"))
        XCTAssertNil(HomeVaultLogic.meshNpub(fromInput: ""))
    }

    func testAMeshOnlyListIsNeverPublished() {
        XCTAssertNil(HomeVaultLogic.mergeServerList(existing: [mesh(kiosk)], current: [], previouslyManaged: [],
                                                    ownMeshNpub: me, shareOwnMesh: true))
    }

    func testMalformedMeshEntriesAreDropped() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/", "fipsmesh://\(kiosk)/evil"], current: [],
                                                 previouslyManaged: [], ownMeshNpub: nil, shareOwnMesh: false)
        XCTAssertEqual(out, ["https://a.example/"])
    }
}

final class ServerListStampTests: XCTestCase {
    func testNewerWinsAndATieGoesToTheLowerId() {
        XCTAssertTrue(HomeVaultLogic.isNewer(createdAt: 5, id: "b", than: nil))
        XCTAssertTrue(HomeVaultLogic.isNewer(createdAt: 6, id: "z", than: (5, "a")))
        XCTAssertFalse(HomeVaultLogic.isNewer(createdAt: 4, id: "a", than: (5, "z")), "a stale replay")
        XCTAssertTrue(HomeVaultLogic.isNewer(createdAt: 5, id: "a", than: (5, "b")))
        XCTAssertFalse(HomeVaultLogic.isNewer(createdAt: 5, id: "b", than: (5, "b")), "the same event again")
    }
}

final class HomeVaultRetryTests: XCTestCase {
    func testBackoffDoublesFromAMinuteUpToSixHours() {
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 1), 60)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 2), 120)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 4), 480)
        XCTAssertEqual(HomeVaultLogic.backoff(afterAttempts: 30), 6 * 3600)
    }

    func testItemsExpireByAgeOrTries() {
        let now = Date(timeIntervalSince1970: 100 * 86400)
        func item(daysOld: Double, attempts: Int) -> HomeVaultItem {
            HomeVaultItem(kind: .blob, id: "b", ownerHex: "aa", eventJSON: nil, contentType: nil,
                          added: now.addingTimeInterval(-daysOld * 86400), attempts: attempts, notBefore: nil)
        }
        XCTAssertFalse(HomeVaultLogic.isExpired(item(daysOld: 13, attempts: 39), now: now))
        XCTAssertTrue(HomeVaultLogic.isExpired(item(daysOld: 15, attempts: 1), now: now))
        XCTAssertFalse(HomeVaultLogic.isExpired(item(daysOld: 15, attempts: 0), now: now), "a clock jump must not delete what was never tried")
        XCTAssertTrue(HomeVaultLogic.isExpired(item(daysOld: 0, attempts: 40), now: now))
    }

    func testAQueueWrittenBeforeBackoffStillLoads() throws {
        let old = #"[{"kind":"event","id":"e1","ownerHex":"aa","eventJSON":"{}","added":0,"attempts":1}]"#
        let items = try JSONDecoder().decode([HomeVaultItem].self, from: Data(old.utf8))
        XCTAssertEqual(items.first?.notBefore, nil)
    }

    func testTheKioskOnlyLinkIsThePublicServersAddress() {
        let sha = String(repeating: "a", count: 64)
        XCTAssertEqual(HomeVaultLogic.publicBlobURL(server: "https://blossom.primal.net/", sha256: sha, contentType: "image/jpeg")?.absoluteString,
                       "https://blossom.primal.net/\(sha).jpg")
        XCTAssertEqual(HomeVaultLogic.publicBlobURL(server: "https://b.example", sha256: sha, contentType: "application/x-thing")?.absoluteString,
                       "https://b.example/\(sha)")
        XCTAssertNil(HomeVaultLogic.publicBlobURL(server: "fipsmesh://npub1x/", sha256: sha, contentType: "image/png"), "never a mesh address")
        XCTAssertNil(HomeVaultLogic.publicBlobURL(server: "https://npub1x.fips", sha256: sha, contentType: "image/png"))
        XCTAssertNil(HomeVaultLogic.publicBlobURL(server: "http://127.0.0.1:3355", sha256: sha, contentType: "image/png"), "never loopback")
    }
}

final class HomeVaultLinkTests: XCTestCase {
    private let sha = String(repeating: "b", count: 64)

    func testAPrivateServerNeverBecomesAPublicLink() {
        for server in ["https://192.168.1.5:4443", "https://10.0.0.2", "https://mac.tail1234.ts.net",
                       "https://100.100.1.1", "https://nas.local", "https://blossom.lan"] {
            XCTAssertNil(HomeVaultLogic.publicBlobURL(server: server, sha256: sha, contentType: "image/png"), server)
        }
        XCTAssertEqual(HomeVaultLogic.linkServer(mirrors: ["https://192.168.1.5:4443", "https://blossom.band/"], sha256: sha, contentType: "image/png"),
                       "https://blossom.band/", "the first public one, skipping the home server")
        XCTAssertNil(HomeVaultLogic.linkServer(mirrors: ["https://10.0.0.2"], sha256: sha, contentType: "image/png"))
    }
}
