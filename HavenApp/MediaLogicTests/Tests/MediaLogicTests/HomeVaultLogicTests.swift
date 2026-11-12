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
        // A note sent on is marked second-hand: the other device stores it and
        // does not blast it again (this device already did; haven-go isSecondHandConn).
        XCTAssertEqual(HomeVaultLogic.eventWebsocketURL(base: base)?.absoluteString,
                       "ws://127.0.0.1:41234/0123456789abcdef0123456789abcdef?pulled=1")
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
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 400), .unreachable("HTTP 400"), "a cut body, or plain HTTP on a TLS port: this try, not the blob")
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
                                                 ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", mesh(kiosk)])
    }

    func testOtherMeshEntriesKeepTheirOrder() {
        let existing = ["https://a.example/", mesh(third), mesh(kiosk)]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", mesh(third), mesh(kiosk)])
    }

    func testOnlyServersThisPhoneManagedAreRemoved() {
        // b was ours and is gone from config; c is another phone's.
        let existing = ["https://a.example/", "https://b.example/", "https://c.example/"]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example"],
                                                 previouslyManaged: ["https://a.example/", "https://b.example/"],
                                                 ownMeshNpub: nil)
        // a keeps the list's own spelling: their entries are not rewritten.
        XCTAssertEqual(out, ["https://a.example/", "https://c.example/"])
    }

    func testTheirOrderStaysFirstAndOursGoAfter() {
        // Logen 2026-10-31: a list set in another app keeps its order; this
        // phone's servers (Primal, the Mac) never jump ahead of it.
        let existing = ["https://their-first.example", "https://blossom.primal.net", "https://their-last.example"]
        let out = HomeVaultLogic.mergeServerList(
            existing: existing,
            current: ["https://blossom.primal.net", "https://mac.example.com", "https://new.example"],
            previouslyManaged: [], ownMeshNpub: nil)
        XCTAssertEqual(out, existing + ["https://mac.example.com", "https://new.example"])
    }

    func testNoListOfTheirsUsesOurs() {
        let out = HomeVaultLogic.mergeServerList(existing: [], current: ["https://blossom.primal.net", "https://mac.example.com"],
                                                 previouslyManaged: [], ownMeshNpub: nil)
        XCTAssertEqual(out, ["https://blossom.primal.net", "https://mac.example.com"])
    }

    func testThisDevicesMainNpubIsNeverListedAndAnOldEntryIsDropped() {
        // The main node is for the owner's own devices: an older list that named it loses it.
        let existing = [mesh(me), "https://a.example/", mesh(kiosk), "https://other-phone.example/"]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", "https://other-phone.example/", mesh(kiosk)])
    }

    func testThePhotoNodeIsListedLast() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/", mesh(kiosk)], current: ["https://a.example/"],
                                                 previouslyManaged: [], ownMeshNpub: me, photoNpub: third)
        XCTAssertEqual(out, ["https://a.example/", mesh(kiosk), mesh(third)])
        // Already listed: once, where it was.
        let again = HomeVaultLogic.mergeServerList(existing: out ?? [], current: ["https://a.example/"],
                                                   previouslyManaged: [], ownMeshNpub: me, photoNpub: third)
        XCTAssertEqual(again, out)
    }

    func testNoPhotoNodeListsNothingAndNeverFallsBackToTheMainNpub() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"],
                                                 previouslyManaged: [], ownMeshNpub: me, photoNpub: nil)
        XCTAssertEqual(out, ["https://a.example/"])
        // A photo npub equal to the main one is refused, not listed.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"],
                                                      previouslyManaged: [], ownMeshNpub: me, photoNpub: me), ["https://a.example/"])
        // The file's text as written (trailing newline) is read; garbage is not.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: [], previouslyManaged: [],
                                                      ownMeshNpub: nil, photoNpub: "\(third)\n"), ["https://a.example/", mesh(third)])
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: [], previouslyManaged: [],
                                                      ownMeshNpub: nil, photoNpub: "not an npub"), ["https://a.example/"])
    }

    func testTheMacListsItsPhotoNodeOnlyWhileItsEngineRuns() {
        // Switch on, but no device added (or the start failed): the engine is not running, nothing is listed.
        let dead = HomeVaultLogic.macPhotoNpub(third, engineRunning: false)
        XCTAssertNil(dead)
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"],
                                                      previouslyManaged: [], ownMeshNpub: nil, photoNpub: dead),
                       ["https://a.example/"])
        XCTAssertFalse(HomeVaultLogic.photoNodeMissing(from: ["https://a.example/"], photoNpub: dead), "no republish for a dead node")
        // Running with a device: listed.
        let live = HomeVaultLogic.macPhotoNpub(third, engineRunning: true)
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"],
                                                      previouslyManaged: [], ownMeshNpub: nil, photoNpub: live),
                       ["https://a.example/", mesh(third)])
        XCTAssertNil(HomeVaultLogic.macPhotoNpub(nil, engineRunning: true), "switch off")
    }

    func testAPhoneKeepsTheMacsPhotoNodeWhenItRepublishes() {
        // The Mac listed its photo node; a phone that knows nothing of it republishes its own servers.
        let macList = ["https://a.example/", mesh(third)]
        let out = HomeVaultLogic.mergeServerList(existing: macList, current: ["https://a.example/", "https://b.example/"],
                                                 previouslyManaged: ["https://a.example/"], ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", "https://b.example/", mesh(third)])
    }

    func testAWithdrawnKioskEntryIsNotPutBack() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/"], current: ["https://a.example/"], previouslyManaged: [],
                                                 ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/"])
    }

    func testASenderListsItsHomeVaultAfterOtherMeshEntries() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/", mesh(third)],
                                                 current: ["https://a.example/", mesh(kiosk)], previouslyManaged: [],
                                                 ownMeshNpub: me)
        XCTAssertEqual(out, ["https://a.example/", mesh(third), mesh(kiosk)])
    }

    func testARemovedEntryDropsThatOneOnly() {
        // This phone listed kiosk before; the owner removes it and adds third.
        // Another phone's entry stays. Without the Remove, kiosk would stay too.
        let existing = ["https://a.example/", mesh(kiosk), mesh(fourth)]
        let out = HomeVaultLogic.mergeServerList(existing: existing, current: ["https://a.example/", mesh(third)],
                                                 previouslyManaged: ["https://a.example/", mesh(kiosk)],
                                                 ownMeshNpub: me, removed: [mesh(kiosk)])
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
                                                    ownMeshNpub: me, photoNpub: third))
    }

    func testAHomeAddressOnlyListIsNeverPublished() {
        // Tod 2026-10-21: no home address is ever published, so a LAN, Tailscale
        // or plain-http entry does not let a 10063 go out on its own.
        for home in ["http://192.168.1.5:4443", "https://192.168.1.5:4443/", "https://box.tail1234.ts.net/",
                     "https://100.101.102.103/", "https://mac.local/", "http://a.example/", "https://x.FIPS./"] {
            XCTAssertNil(HomeVaultLogic.mergeServerList(existing: [], current: [home], previouslyManaged: [], ownMeshNpub: nil),
                         home)
            XCTAssertNil(HomeVaultLogic.mergeServerList(existing: [home], current: [], previouslyManaged: [], ownMeshNpub: me,
                                                        photoNpub: third), home)
            XCTAssertFalse(HomeVaultLogic.isPublicServer(home), home)
        }
        // Next to a real public server it is kept, as another phone's entry.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: ["http://192.168.1.5:4443"], current: ["https://a.example/"],
                                                      previouslyManaged: [], ownMeshNpub: nil),
                       ["http://192.168.1.5:4443", "https://a.example/"])
    }

    func testAFipsHostIsMeshOnlyAndNeverCountsAsAPublicServer() {
        // Tara's NIP-F1 check: http://npub….fips:port resolves only on the mesh; a list of only that must not go out.
        for meshOnly in ["http://\(kiosk).fips:8080/", "https://\(kiosk).fips/", "http://\(kiosk).FIPS./", "https://box.fips", "http://fips/"] {
            XCTAssertNil(HomeVaultLogic.mergeServerList(existing: [], current: [meshOnly], previouslyManaged: [], ownMeshNpub: nil),
                         meshOnly)
            XCTAssertFalse(HomeVaultLogic.isReachableWithoutMesh(meshOnly), meshOnly)
        }
        for usable in ["https://a.example/", "https://fips.example.com/", "https://notfips/", "http://192.168.1.5:4443"] {
            XCTAssertTrue(HomeVaultLogic.isReachableWithoutMesh(usable), usable)
        }
        XCTAssertFalse(HomeVaultLogic.isReachableWithoutMesh(mesh(kiosk)))
        XCTAssertFalse(HomeVaultLogic.isReachableWithoutMesh("not a url"))
        // With a real public server, a .fips entry is kept, after it.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: [], current: ["https://a.example/", "http://\(kiosk).fips:8080/"],
                                                      previouslyManaged: [], ownMeshNpub: nil),
                       ["https://a.example/", "http://\(kiosk).fips:8080/"])
    }

    func testMalformedMeshEntriesAreDropped() {
        let out = HomeVaultLogic.mergeServerList(existing: ["https://a.example/", "fipsmesh://\(kiosk)/evil"], current: [],
                                                 previouslyManaged: [], ownMeshNpub: nil)
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

    func testAnUnsignedListIsNeverKeptAndNeverBeatsTheRealOne() {
        // Tara's NIP-F1 check: a relay can serve any 10063 under any author. Only a signed one picks the mesh node.
        XCTAssertFalse(HomeVaultLogic.keepsServerList(signedByAuthor: false, createdAt: 9, id: "a", than: nil))
        XCTAssertFalse(HomeVaultLogic.keepsServerList(signedByAuthor: false, createdAt: 99, id: "a", than: (5, "z")),
                       "a forged newer list")
        XCTAssertTrue(HomeVaultLogic.keepsServerList(signedByAuthor: true, createdAt: 6, id: "a", than: (5, "z")))
        XCTAssertFalse(HomeVaultLogic.keepsServerList(signedByAuthor: true, createdAt: 4, id: "a", than: (5, "z")), "newest wins")
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

/// Photos through the Mac: with no server on the phone, media goes to the Mac
/// over the mesh and the Mac passes it on to the owner's public server.
final class MacMediaVaultTests: XCTestCase {
    private let owner = String(repeating: "a", count: 64)
    private let macNpub = "npub1z2g42utgkc5tv49xgwy7lplfd8048vuwv9krcc23m828kdjm3cl68tgcyy"
    private let kioskNpub = "npub1h8ts9gragczufl8v44chxgut0a870ranmjws865ejtvphmn0czt7cp5dae"

    func testMacIsTheMediaVaultOnlyWithoutAKiosk() {
        XCTAssertEqual(HomeVaultLogic.mediaVault(homeVault: nil, macMeshNpub: macNpub, ownerHex: owner),
                       HomeVault(ownerHex: owner, meshNpub: macNpub))
        let kiosk = HomeVault(ownerHex: owner, meshNpub: kioskNpub)
        XCTAssertEqual(HomeVaultLogic.mediaVault(homeVault: kiosk, macMeshNpub: macNpub, ownerHex: owner), kiosk)
        XCTAssertNil(HomeVaultLogic.mediaVault(homeVault: nil, macMeshNpub: nil, ownerHex: owner))
        XCTAssertNil(HomeVaultLogic.mediaVault(homeVault: nil, macMeshNpub: macNpub, ownerHex: ""), "no account, no vault")
    }

    /// Linking a device no longer lists it (Logen via Tod, 2026-11-08): the
    /// list's mesh entries change only by Media Servers' Add and Remove.
    func testMeshEntriesChangeOnlyByAddOrRemove() {
        let https = "https://logen.btcforplebs.com"
        let mac = "fipsmesh://\(macNpub)/"
        // A publish for a typed server: no mesh entry appears.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: [https], current: [https],
                                                      previouslyManaged: [https], ownMeshNpub: kioskNpub), [https])
        // Add to my media servers.
        let added = HomeVaultLogic.mergeServerList(existing: [https], current: [https, mac],
                                                   previouslyManaged: [https], ownMeshNpub: kioskNpub)
        XCTAssertEqual(added, [https, mac])
        // The next typed-server publish keeps it, even though this phone
        // listed it last time (an older build managed mesh entries).
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: added!, current: [https, "https://blossom.band"],
                                                      previouslyManaged: [https, mac], ownMeshNpub: kioskNpub),
                       [https, "https://blossom.band", mac])
        // Remove takes it off, whoever listed it, in any address form.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: added!, current: [https], previouslyManaged: [https],
                                                      ownMeshNpub: kioskNpub, removed: ["FIPSMESH://\(macNpub)"]),
                       [https])
        // Added and removed at once: removed wins.
        XCTAssertEqual(HomeVaultLogic.mergeServerList(existing: [https], current: [https, mac], previouslyManaged: [],
                                                      ownMeshNpub: kioskNpub, removed: [mac]), [https])
        // Mesh only: never published.
        XCTAssertNil(HomeVaultLogic.mergeServerList(existing: [], current: [mac], previouslyManaged: [], ownMeshNpub: kioskNpub))
    }

    func testMeshMediaServerRows() {
        let phone = "npub1" + String(repeating: "f", count: 58)
        let browser = "npub1" + String(repeating: "w", count: 58)
        let stray = "npub1" + String(repeating: "s", count: 58)
        let devices = [
            MeshDevice(npub: macNpub, name: "Studio Mac", role: .mac),
            MeshDevice(npub: kioskNpub, name: "", role: .homeVault),
            MeshDevice(npub: phone, name: "Moto", role: .phone),
            MeshDevice(npub: browser, name: "", role: .browser),
        ]
        let listed = ["https://a.example", "fipsmesh://\(kioskNpub)/", "fipsmesh://\(stray)/", "fipsmesh://\(phone)/", "fipsmesh://bad/"]
        let rows = HomeVaultLogic.meshMediaServerRows(devices: devices, listed: listed, own: nil, photoNpub: nil)
        XCTAssertEqual(rows.map(\.npub), [macNpub, kioskNpub, stray, phone], "vaults first; phones and browser only when already listed")
        XCTAssertEqual(rows.map(\.listed), [false, true, true, true])
        XCTAssertEqual(rows[0].name, "Studio Mac")
        XCTAssertNil(rows[2].name, "not in My Devices")
        XCTAssertEqual(rows[3].role, .phone, "an old listing of a phone can still be removed")
        XCTAssertEqual(rows[1].entry, "fipsmesh://\(kioskNpub)/")

        // This device is never a row; this Mac's photo node is, not removable.
        let mac = HomeVaultLogic.meshMediaServerRows(devices: devices, listed: ["fipsmesh://\(stray)/"], own: stray, photoNpub: kioskNpub)
        XCTAssertEqual(mac.map(\.npub), [macNpub, kioskNpub])
        XCTAssertEqual(mac.map(\.removable), [true, false])
    }

    func testForwardServerIsTheFirstPublicEntryOfTheOwnersList() {
        let list = ["fipsmesh://\(kioskNpub)/", "https://192.168.1.5:4443", "https://logen.btcforplebs.com", "https://blossom.band"]
        XCTAssertEqual(HomeVaultLogic.forwardServer(phoneMirrors: [], ownerServerList: list), "https://logen.btcforplebs.com")
        XCTAssertNil(HomeVaultLogic.forwardServer(phoneMirrors: [], ownerServerList: ["http://plain.example", "https://mac.tail1.ts.net"]),
                     "only a server any reader can open")
        XCTAssertNil(HomeVaultLogic.forwardServer(phoneMirrors: [], ownerServerList: []))
    }

    /// A phone with its own server uploads itself; the vault forwards nothing.
    func testNoForwardWhileThePhoneHasAServer() {
        XCTAssertNil(HomeVaultLogic.forwardServer(phoneMirrors: ["https://blossom.band"], ownerServerList: ["https://logen.btcforplebs.com"]))
    }

    func testPublicServerRule() {
        XCTAssertTrue(HomeVaultLogic.isPublicServer("https://logen.btcforplebs.com"))
        for s in ["http://logen.btcforplebs.com", "https://npub1x.fips", "https://10.0.0.2", "https://127.0.0.1:3355", "fipsmesh://\(macNpub)/"] {
            XCTAssertFalse(HomeVaultLogic.isPublicServer(s), s)
        }
    }
    func testThePhotoNodeIsMissingUntilTheKeptListNamesIt() {
        // Logen's 2026-10-21 list: only the public server, no Mac entry.
        let kept = ["https://logen.btcforplebs.com"]
        XCTAssertTrue(HomeVaultLogic.photoNodeMissing(from: kept, photoNpub: macNpub))
        XCTAssertTrue(HomeVaultLogic.photoNodeMissing(from: kept + ["fipsmesh://\(kioskNpub)/"], photoNpub: macNpub), "another node is not ours")
        XCTAssertFalse(HomeVaultLogic.photoNodeMissing(from: kept + ["fipsmesh://\(macNpub)/"], photoNpub: macNpub))
        XCTAssertFalse(HomeVaultLogic.photoNodeMissing(from: kept, photoNpub: nil), "Mesh off")
        XCTAssertFalse(HomeVaultLogic.photoNodeMissing(from: nil, photoNpub: macNpub), "no list seen yet")
    }
}

/// Every linked phone gets this phone's new notes and media, each on its own lane (Logen 2026-11-05).
final class HomeVaultPhoneLaneTests: XCTestCase {

    private func device(_ npub: String, _ role: MeshDeviceRole) -> MeshDevice {
        MeshDevice(npub: npub, name: "", role: role)
    }

    private func sendItem(_ kind: HomeVaultItem.Kind, _ id: String, to target: String? = nil) -> HomeVaultItem {
        HomeVaultItem(kind: kind, id: id, ownerHex: "o", eventJSON: nil, contentType: nil,
                      added: Date(timeIntervalSince1970: 0), attempts: 0, notBefore: nil, target: target)
    }

    func testEveryLinkedPhoneIsATargetOnceButNotThisPhoneOrTheHomeVaultOrMac() {
        let devices = [device("phoneA", .phone), device("me", .phone), device("phoneB", .phone),
                       device("phoneA", .phone), device("kiosk", .homeVault), device("mac", .mac),
                       device("page", .browser), device("kioskAsPhone", .phone)]
        XCTAssertEqual(HomeVaultLogic.phoneTargets(devices: devices, ownNpub: "me", homeVault: "kioskAsPhone", mac: "mac"),
                       ["phoneA", "phoneB"])
        XCTAssertEqual(HomeVaultLogic.phoneTargets(devices: [device("mac", .mac)], ownNpub: nil, homeVault: nil, mac: nil), [])
    }

    func testTheSameSendIsPerLane() {
        XCTAssertTrue(HomeVaultLogic.sameSend(sendItem(.event, "e1"), sendItem(.event, "e1")))
        XCTAssertFalse(HomeVaultLogic.sameSend(sendItem(.event, "e1"), sendItem(.event, "e1", to: "phoneA")),
                       "the home vault's copy and a phone's copy are two sends")
        XCTAssertFalse(HomeVaultLogic.sameSend(sendItem(.event, "e1", to: "phoneA"), sendItem(.event, "e1", to: "phoneB")))
        XCTAssertFalse(HomeVaultLogic.sameSend(sendItem(.blob, "e1"), sendItem(.event, "e1")))
    }

    func testEachLaneHasItsOwnCap() {
        let full = (0..<3).map { sendItem(.event, "p\($0)", to: "phoneA") }
        XCTAssertFalse(HomeVaultLogic.hasRoom(for: sendItem(.event, "x", to: "phoneA"), in: full, max: 3))
        XCTAssertTrue(HomeVaultLogic.hasRoom(for: sendItem(.event, "x"), in: full, max: 3), "a full phone lane can't stop the home vault")
        XCTAssertTrue(HomeVaultLogic.hasRoom(for: sendItem(.event, "x", to: "phoneB"), in: full, max: 3))
    }

    func testAnIPhoneTakesSendsWhileOpenWithAPhoneLinked() {
        XCTAssertTrue(HomeVaultLogic.sharesWhileOpen(meshOn: true, appActive: true, alreadySharing: false, linkedPhones: 1))
        XCTAssertFalse(HomeVaultLogic.sharesWhileOpen(meshOn: false, appActive: true, alreadySharing: false, linkedPhones: 1))
        XCTAssertFalse(HomeVaultLogic.sharesWhileOpen(meshOn: true, appActive: false, alreadySharing: false, linkedPhones: 1))
        XCTAssertFalse(HomeVaultLogic.sharesWhileOpen(meshOn: true, appActive: true, alreadySharing: true, linkedPhones: 1))
        XCTAssertFalse(HomeVaultLogic.sharesWhileOpen(meshOn: true, appActive: true, alreadySharing: false, linkedPhones: 0))
    }

    func testAQueueSavedBeforeLanesStaysTheHomeVaults() throws {
        let old = #"[{"kind":"event","id":"e1","ownerHex":"o","added":0,"attempts":0}]"#
        let items = try JSONDecoder().decode([HomeVaultItem].self, from: Data(old.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].target)
        let laned = try JSONDecoder().decode([HomeVaultItem].self, from: JSONEncoder().encode([sendItem(.blob, "b", to: "phoneA")]))
        XCTAssertEqual(laned[0].target, "phoneA")
    }

    // MARK: Signed deletes in the send queue (device sync map §4.3)

    private func queued(_ kind: HomeVaultItem.Kind, _ id: String, owner: String = "aa") -> HomeVaultItem {
        HomeVaultItem(kind: kind, id: id, ownerHex: owner, eventJSON: kind == .event ? "{}" : nil,
                      contentType: nil, added: Date(), attempts: 0, notBefore: nil)
    }

    func testADeleteNamesItsNotes() {
        let del: [String: Any] = ["kind": 5, "pubkey": "aa", "tags": [["e", "n1"], ["e", "n2"], ["a", "30023:aa:x"], ["k", "1"]]]
        XCTAssertEqual(HomeVaultLogic.deletedEventIDs(del), ["n1", "n2"])
        XCTAssertEqual(HomeVaultLogic.deletedEventIDs(["kind": 1, "tags": [["e", "n1"]]]), [])
    }

    /// A note deleted while it waited for the home vault is never sent; a
    /// delete by someone else takes nothing; a deleted blob's sends go too.
    func testADeleteTakesBackWhatWaits() {
        let queue = [queued(.blob, "b1"), queued(.mirror, "b1"), queued(.blob, "b2"),
                     queued(.event, "n1"), queued(.event, "n2"), queued(.event, "n3", owner: "bb")]
        let afterNote = HomeVaultLogic.droppingDeleted(queue, eventIDs: ["n1", "n3"], author: "aa", blob: nil)
        XCTAssertEqual(afterNote.map(\.id), ["b1", "b1", "b2", "n2", "n3"], "n3 is someone else's: kept")
        let afterBlob = HomeVaultLogic.droppingDeleted(queue, eventIDs: [], author: nil, blob: "b1")
        XCTAssertEqual(afterBlob.map(\.id), ["b2", "n1", "n2", "n3"])
    }
}
