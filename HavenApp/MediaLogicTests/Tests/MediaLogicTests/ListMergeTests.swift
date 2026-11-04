import XCTest
@testable import MediaLogic

/// NIP-51 lists are replaceable: publishing only this device's entries used to
/// delete what other clients had set (Android twin: `ListMergeTest.kt`).
final class ListMergeTests: XCTestCase {
    func testMuteListKeepsWordHashtagAndThreadMutesAndReplacesPTags() {
        let published = [["p", "aaa"], ["p", "gone"], ["word", "spoiler"], ["t", "nsfw"], ["e", "thread1"]]
        let tags = ListMerge.tags(name: "p", local: ["aaa", "bbb"], published: published) { _ in false }
        XCTAssertEqual(tags, [["p", "aaa"], ["p", "bbb"], ["word", "spoiler"], ["t", "nsfw"], ["e", "thread1"]])
    }

    func testEntryAnotherClientAddedStaysOneRemovedHereGoes() {
        let base: Set<String> = ["wss://removed.example", "wss://kept.example"]
        let published = [["relay", "wss://kept.example"], ["relay", "wss://removed.example"], ["relay", "wss://other-client.example"]]
        let tags = ListMerge.tags(name: "relay", local: ["wss://kept.example"], published: published) { !base.contains(ListMerge.key($0)) }
        XCTAssertEqual(tags, [["relay", "wss://kept.example"], ["relay", "wss://other-client.example"]])
    }

    func testNoBaseKeepsEveryPublishedEntryOnceAfterLocalOnesInOrder() {
        let published = [["server", "https://b.example/"], ["server", "https://c.example"]]
        let tags = ListMerge.tags(name: "server", local: ["https://a.example", "https://B.example"], published: published) { _ in true }
        XCTAssertEqual(tags, [["server", "https://a.example"], ["server", "https://B.example"], ["server", "https://c.example"]])
    }

    func testNothingPublishedPublishesTheLocalList() {
        XCTAssertEqual(ListMerge.tags(name: "p", local: ["x", "X", " "], published: []) { _ in true }, [["p", "x"]])
    }

    func testBasesAreSavedPerListAndSurviveANewInstance() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ListMerge.basesFileName)
        XCTAssertNil(ListMerge.Bases(file: file).get("10006:abc"))
        ListMerge.Bases(file: file).put("10006:abc", ["wss://a"])
        ListMerge.Bases(file: file).put("10063:abc", ["https://m"])
        XCTAssertEqual(ListMerge.Bases(file: file).get("10006:abc"), ["wss://a"])
        XCTAssertEqual(ListMerge.Bases(file: file).get("10063:abc"), ["https://m"])
    }

    // MARK: - Block / unblock on a mute list another app wrote

    /// Amethyst's shape: public people, words, hashtags and a thread, and an
    /// encrypted private part in content (kept by the caller as is).
    private let amethystList: [[String]] = [
        ["p", "a1"], ["p", "b2", "wss://relay.example", "pet"], ["word", "spoiler"],
        ["t", "nsfw"], ["e", "thread1"], ["p", "C3"],
    ]

    func testBlockKeepsEveryOldEntryAndAddsOne() {
        let tags = ListMerge.edit(name: "p", base: amethystList, add: ["d4"], remove: [])
        XCTAssertEqual(tags, amethystList + [["p", "d4"]])
    }

    /// The bug: the device's own (older) list replaced every p tag, so people
    /// another app had just blocked came back unblocked.
    func testBlockWithAStaleLocalListStillKeepsTheOtherAppsPeople() {
        let tags = ListMerge.edit(name: "p", base: amethystList, add: ["a1"], remove: [])
        XCTAssertEqual(tags, amethystList)
    }

    func testUnblockRemovesOnlyThatEntry() {
        let tags = ListMerge.edit(name: "p", base: amethystList, add: [], remove: ["c3"])
        XCTAssertEqual(tags, [["p", "a1"], ["p", "b2", "wss://relay.example", "pet"], ["word", "spoiler"], ["t", "nsfw"], ["e", "thread1"]])
    }

    func testUnblockLeavesAWordOrThreadWithTheSameValue() {
        let tags = ListMerge.edit(name: "p", base: [["word", "x"], ["e", "x"], ["p", "x"]], add: [], remove: ["x"])
        XCTAssertEqual(tags, [["word", "x"], ["e", "x"]])
    }

    func testEditBaseTakesTheNewerOfFetchedAndHeld() {
        let own = ["wss://a.example", "wss://b.example"]
        let fetched = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 2, answeredBy: ["wss://a.example", "wss://b.example"], from: ["wss://a.example"])
        guard case .list(let newest) = ListMerge.editBase(fetched, held: 200, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(newest, 200)
        guard case .list(let fetchedOnly) = ListMerge.editBase(fetched, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(fetchedOnly, 100)
    }

    func testEditBaseIsUnknownWhenTheFetchFails() {
        let own = ["wss://a.example", "wss://b.example", "wss://c.example"]
        let nobody = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 0)
        guard case .unknown = ListMerge.editBase(nobody, held: 200, own: own, createdAt: { $0 }) else { return XCTFail("published on a failed fetch") }
        let some = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 2, answeredBy: Set(own.prefix(2)))
        guard case .unknown = ListMerge.editBase(some, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("published with a relay unanswered") }
        let all = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 3, answeredBy: Set(own))
        guard case .none = ListMerge.editBase(all, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list anywhere should be none") }
        guard case .noRelayList = ListMerge.editBase(all, held: nil, own: [], createdAt: { $0 }) else { return XCTFail("no own relays must be noRelayList") }
    }

    /// Sweep 11-01 #2: a new account's first follow was rolled back when one
    /// relay was silent. A key setup made here can't have a list anywhere.
    func testFreshKeyBaseBuildsOnWhatIsSeenWhenARelayIsSilent() {
        let own = ["wss://a.example", "wss://b.example", "wss://c.example"]
        let some = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 2, answeredBy: Set(own.prefix(2)))
        let found = ListMerge.editBase(some, held: nil, own: own, createdAt: { $0 })
        guard case .unknown = found else { return XCTFail("setup: expected unknown") }
        guard case .none = ListMerge.freshKeyBase(found, fresh: true, lookup: some, held: nil, createdAt: { $0 }) else { return XCTFail("fresh key, silent relay should be none") }
        // Not fresh: unchanged, still refused.
        guard case .unknown = ListMerge.freshKeyBase(found, fresh: false, lookup: some, held: nil, createdAt: { $0 }) else { return XCTFail("non-fresh key must stay unknown") }
        // Nobody answered, no relay list yet: a fresh key still builds on its held copy.
        let nobody = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 0)
        let noList = ListMerge.editBase(nobody, held: 200, own: [], createdAt: { $0 })
        guard case .noRelayList = noList else { return XCTFail("setup: expected noRelayList") }
        guard case .list(let held) = ListMerge.freshKeyBase(noList, fresh: true, lookup: nobody, held: 200, createdAt: { $0 }) else { return XCTFail("fresh key should build on the held copy") }
        XCTAssertEqual(held, 200)
        // The newest of the fetched and held copies.
        let fetched = ReplaceableLookup<Int64>(event: 300, asked: 3, answered: 1, answeredBy: ["wss://x.example"], from: ["wss://x.example"])
        guard case .list(let newest) = ListMerge.freshKeyBase(.unknown, fresh: true, lookup: fetched, held: 200, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(newest, 300)
    }

    func testFreshKeyBaseKeepsUnknownWhenACopyIsAhead() {
        let now: Int64 = 1_000_000
        let ahead = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 1, ahead: true)
        guard case .unknown = ListMerge.freshKeyBase(.unknown, fresh: true, lookup: ahead, held: nil, now: now, createdAt: { $0 }) else { return XCTFail("a list exists somewhere") }
        let future = ReplaceableLookup<Int64>(event: now + ListMerge.maxSkew, asked: 3, answered: 1)
        guard case .unknown = ListMerge.freshKeyBase(.unknown, fresh: true, lookup: future, held: nil, now: now, createdAt: { $0 }) else { return XCTFail("built over a far-ahead copy") }
        // A list that is known stays as it is.
        guard case .list(let list) = ListMerge.freshKeyBase(.list(5 as Int64), fresh: true, lookup: future, held: nil, now: now, createdAt: { $0 }) else { return XCTFail("list changed") }
        XCTAssertEqual(list, 5)
    }

    func testEditBaseIsUnknownOnACopyNoOwnRelayVouchesFor() {
        let own = ["wss://mine.example"]
        // Only purplepag.es answered; the user's relay timed out.
        let stale = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                      answeredBy: ["wss://purplepag.es"], from: ["wss://purplepag.es"])
        guard case .unknown = ListMerge.editBase(stale, held: 50, own: own, createdAt: { $0 }) else { return XCTFail("built on a stale copy") }
        // The user's relay sent it alone: one answer is never enough (Logen 2026-11-02).
        let alone = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                      answeredBy: ["wss://mine.example/"], from: ["wss://mine.example/"])
        guard case .unknown = ListMerge.editBase(alone, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("one answer") }
        // The user's relay sent it and another relay answered too.
        let fromMine = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 2,
                                         answeredBy: ["wss://mine.example/", "wss://purplepag.es"], from: ["wss://mine.example/"])
        guard case .list(let list) = ListMerge.editBase(fromMine, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(list, 100)
        // The user's relay answered with an older copy; the newer one counts.
        let newerElsewhere = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 2,
                                               answeredBy: ["wss://mine.example", "wss://purplepag.es"], from: ["wss://purplepag.es"])
        guard case .list = ListMerge.editBase(newerElsewhere, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
    }

    /// Tron #1459: the write relays time out and purplepag.es (or a read relay)
    /// answers with an older list. That copy must not become the base, and
    /// neither must a copy this device holds.
    func testEditBaseNeedsTheOwnRelaysNotJustAnyAnswer() {
        let write = ["wss://w1.example", "wss://w2.example", "wss://w3.example"]
        let old = ReplaceableLookup(event: 100 as Int64, asked: 6, answered: 1,
                                    answeredBy: ["wss://purplepag.es"], from: ["wss://purplepag.es"])
        guard case .unknown = ListMerge.editBase(old, held: nil, own: write, createdAt: { $0 }) else { return XCTFail("built on purplepag.es alone") }
        guard case .unknown = ListMerge.editBase(old, held: 150, own: write, createdAt: { $0 }) else { return XCTFail("built on a held copy with the own relays silent") }
        // One of three write relays answered empty, purplepag.es sent a list: not most of them.
        let one = ReplaceableLookup(event: 100 as Int64, asked: 6, answered: 2,
                                    answeredBy: ["wss://purplepag.es", "wss://w1.example"], from: ["wss://purplepag.es"])
        guard case .unknown = ListMerge.editBase(one, held: nil, own: write, createdAt: { $0 }) else { return XCTFail("1 of 3 own relays is not most") }
        // Two of three answered: most of them (Logen 2026-11-02 13:21Z), the newest copy is the base.
        let two = ReplaceableLookup(event: 100 as Int64, asked: 6, answered: 3,
                                    answeredBy: ["wss://purplepag.es", "wss://w1.example", "wss://w2.example"], from: ["wss://purplepag.es"])
        guard case .list(let base) = ListMerge.editBase(two, held: nil, own: write, createdAt: { $0 }) else { return XCTFail("most own relays answered") }
        XCTAssertEqual(base, 100)
        // "None" needs every own relay, even when the other relays all answered.
        let noneButOne = ReplaceableLookup<Int64>(event: nil, asked: 5, answered: 5,
                                                  answeredBy: ["wss://purplepag.es", "wss://r.example", "wss://w1.example", "wss://w2.example", "wss://x.example"])
        guard case .unknown = ListMerge.editBase(noneButOne, held: nil, own: write, createdAt: { $0 }) else { return XCTFail("none with an own relay unheard") }
    }

    /// List-wipe audit 2026-11-02: own relay A answers fast with an old copy,
    /// own relay B holds a newer one and is slow. Building on A's copy dropped
    /// what other apps had added on B. The save waits for B, or refuses.
    func testEditBaseWaitsForEveryOwnRelayNotJustTheOneThatSentACopy() {
        let own = ["wss://a.example", "wss://b.example"]
        // A sent its old copy, B never answered: one answer is never most, even with A vouching.
        let staleA = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                       answeredBy: ["wss://a.example"], from: ["wss://a.example"])
        guard case .unknown = ListMerge.editBase(staleA, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("built on A's copy with B unheard") }
        // A held copy doesn't stand in for B either.
        guard case .unknown = ListMerge.editBase(staleA, held: 90, own: own, createdAt: { $0 }) else { return XCTFail("built on a held copy with B unheard") }
        // B answered in time with the newer copy: that one is the base.
        let both = ReplaceableLookup(event: 200 as Int64, asked: 3, answered: 2,
                                     answeredBy: ["wss://a.example", "wss://b.example/"], from: ["wss://b.example/"])
        guard case .list(let base) = ListMerge.editBase(both, held: 100, own: own, createdAt: { $0 }) else { return XCTFail("every own relay answered") }
        XCTAssertEqual(base, 200)
    }

    /// Logen 2026-11-02 13:21Z: an edit goes ahead once more than half of the
    /// own relays answered, never on one answer or none, and builds on the
    /// newest copy among those that answered.
    func testEditBaseNeedsMoreThanHalfAndAtLeastTwoOwnRelays() {
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 0, own: 1, answered: 3))
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 1, own: 1, answered: 1), "a single answer is never enough")
        XCTAssertTrue(ListMerge.ownMajority(ownAnswered: 1, own: 1, answered: 2), "its one relay and an indexer")
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 1, own: 2, answered: 3))
        XCTAssertTrue(ListMerge.ownMajority(ownAnswered: 2, own: 2, answered: 2))
        XCTAssertTrue(ListMerge.ownMajority(ownAnswered: 2, own: 3, answered: 2))
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 2, own: 4, answered: 5), "half is not more than half")
        XCTAssertTrue(ListMerge.ownMajority(ownAnswered: 3, own: 4, answered: 3))
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 2, own: 5, answered: 6))
        XCTAssertFalse(ListMerge.ownMajority(ownAnswered: 0, own: 0, answered: 4), "no own relays")
        let own = ["wss://a.example", "wss://b.example", "wss://c.example", "wss://d.example"]
        // Half of four answered: refused.
        let half = ReplaceableLookup(event: 100 as Int64, asked: 4, answered: 2,
                                     answeredBy: ["wss://a.example", "wss://b.example"], from: ["wss://a.example"])
        guard case .unknown = ListMerge.editBase(half, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("half is not most") }
        // Three of four: the newest of the copy they sent and the held one.
        let most = ReplaceableLookup(event: 300 as Int64, asked: 4, answered: 3,
                                     answeredBy: ["wss://a.example", "wss://b.example", "wss://c.example"], from: ["wss://c.example"])
        guard case .list(let base) = ListMerge.editBase(most, held: 200, own: own, createdAt: { $0 }) else { return XCTFail("most answered") }
        XCTAssertEqual(base, 300)
        // One own relay: its answer alone never edits, with an indexer's too it does.
        let single = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                       answeredBy: ["wss://a.example"], from: ["wss://a.example"])
        guard case .unknown = ListMerge.editBase(single, held: nil, own: ["wss://a.example"], createdAt: { $0 }) else { return XCTFail("one answer") }
        let pair = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 2,
                                     answeredBy: ["wss://a.example", "wss://x.example"], from: ["wss://a.example"])
        guard case .list = ListMerge.editBase(pair, held: nil, own: ["wss://a.example"], createdAt: { $0 }) else { return XCTFail("own relay + indexer") }
        // "None" still needs every own relay: three of four said none, the fourth may hold the list.
        let noneMost = ReplaceableLookup<Int64>(event: nil, asked: 4, answered: 3,
                                                answeredBy: ["wss://a.example", "wss://b.example", "wss://c.example"])
        guard case .unknown = ListMerge.editBase(noneMost, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("none with an own relay unheard") }
    }

    // MARK: - Unblocking from the private part

    /// Stand-in for NIP-44/NIP-04 to self: NIP-04 output carries "?iv=" as the real one does.
    private static func seal(_ text: String, _ nip04: Bool) -> String {
        nip04 ? Data(text.utf8).base64EncodedString() + "?iv=AAAA" : "v2:" + Data(text.utf8).base64EncodedString()
    }

    private static func open(_ text: String, _ nip04: Bool) throws -> String {
        let body = nip04 ? String(text.prefix { $0 != "?" }) : String(text.dropFirst(3))
        guard let data = Data(base64Encoded: body), let out = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return out
    }

    private func unblock(_ content: String, _ remove: [String], schemes: inout [Bool], knownPrivate: Bool = false,
                         encrypt: ((String, Bool) throws -> String)? = nil) async -> ListMerge.PrivateEdit {
        var used: [Bool] = []
        let result = await ListMerge.removingPrivate(content: content, remove: remove, knownPrivate: knownPrivate,
            decrypt: { used.append($1); return try Self.open($0, $1) },
            encrypt: { text, nip04 in
                used.append(nip04)
                return try (encrypt ?? Self.seal)(text, nip04)
            })
        schemes = used
        return result
    }

    private static let privatePart = #"[["p","aaa"],["p","bbb","wss://r.example/","pet"],["word","spoiler"],["e","thread1"]]"#

    func testUnblockOfAPrivateOnlyPersonTakesThemOutOfTheNip44Part() async throws {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, false), ["AAA"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertFalse(MuteList.isNip04(content))
        XCTAssertEqual(try MuteList.privateTags(fromJSON: Self.open(content, false)),
                       [["p", "bbb", "wss://r.example/", "pet"], ["word", "spoiler"], ["e", "thread1"]])
        XCTAssertEqual(schemes, [false, false, false], "opened, encrypted, opened again to check")
    }

    func testUnblockKeepsANip04PartNip04() async throws {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, true), ["bbb"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertTrue(MuteList.isNip04(content))
        XCTAssertEqual(try MuteList.privateTags(fromJSON: Self.open(content, true)),
                       [["p", "aaa"], ["word", "spoiler"], ["e", "thread1"]])
        XCTAssertEqual(schemes, [true, true, true])
    }

    func testUnblockOfSomeoneNotInThePrivatePartLeavesItAsItIs() async {
        let sealed = Self.seal(Self.privatePart, false)
        var schemes: [Bool] = []
        // A thread with the same value as the person is not a person.
        let result = await unblock(sealed, ["ccc", "thread1"], schemes: &schemes)
        XCTAssertEqual(result, .content(sealed))
        XCTAssertEqual(schemes, [false], "opened, never encrypted again")
    }

    func testBlockAndEmptyContentNeverOpenThePrivatePart() async {
        var schemes: [Bool] = []
        let block = await unblock(Self.seal(Self.privatePart, false), [], schemes: &schemes, knownPrivate: true)
        XCTAssertEqual(block, .content(Self.seal(Self.privatePart, false)))
        XCTAssertEqual(schemes, [])
        let empty = await unblock("", ["aaa"], schemes: &schemes, knownPrivate: true)
        XCTAssertEqual(empty, .content(""))
        XCTAssertEqual(schemes, [])
    }

    func testAPrivatePartThisDeviceCantOpenIsKeptOnlyWhenTheyArentKnownPrivate() async {
        var schemes: [Bool] = []
        let unknown = await unblock("v2:not base64!", ["aaa"], schemes: &schemes)
        XCTAssertEqual(unknown, .content("v2:not base64!"))
        // A signer that won't decrypt (Amber without silent permission, a
        // bunker that's away) must not publish a list that re-blocks them.
        let known = await unblock("v2:not base64!", ["aaa"], schemes: &schemes, knownPrivate: true)
        XCTAssertEqual(known, .failed)
    }

    func testAPrivatePartARewriteWouldLoseFailsWhenReadingItBackStillBlocksThem() async throws {
        // Reading skips the null, number and object; writing can't keep them.
        let odd = Self.seal(#"[["p","aaa",null],["p","bbb",1],{"x":"y"}]"#, false)
        var schemes: [Bool] = []
        let result = await unblock(odd, ["aaa"], schemes: &schemes)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(schemes, [false], "opened, never encrypted again")
        XCTAssertTrue(try MuteList.privateTags(fromJSON: Self.open(odd, false)).contains(["p", "aaa"]))
        // Someone who isn't in it: nothing to rewrite, the part is kept.
        let other = await unblock(odd, ["ccc"], schemes: &schemes)
        XCTAssertEqual(other, .content(odd))
        XCTAssertNil(ListMerge.privateRemoved(plaintext: #"{"p":"aaa"}"#, remove: ["aaa"]))
    }

    func testUnblockIsNotPublishedWhenThePrivatePartCantBeEncryptedAgain() async {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes,
                                   encrypt: { _, _ in throw URLError(.userCancelledAuthentication) })
        XCTAssertEqual(result, .failed)
        let empty = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes, encrypt: { _, _ in "" })
        XCTAssertEqual(empty, .failed)
    }

    func testASignerThatEchoesThePlaintextIsNotPublished() async {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes, encrypt: { text, _ in text })
        XCTAssertEqual(result, .failed)
    }

    func testASignerThatSwitchesSchemeIsNotPublished() async {
        var schemes: [Bool] = []
        let to04 = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes,
                                 encrypt: { text, _ in Self.seal(text, true) })
        XCTAssertEqual(to04, .failed)
        let to44 = await unblock(Self.seal(Self.privatePart, true), ["aaa"], schemes: &schemes,
                                 encrypt: { text, _ in Self.seal(text, false) })
        XCTAssertEqual(to44, .failed)
    }

    func testASignerThatEncryptsSomethingElseIsNotPublished() async {
        // Another key or account: this device opens it to other text, or not at all.
        var schemes: [Bool] = []
        let other = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes,
                                  encrypt: { _, nip04 in Self.seal(#"[["p","zzz"]]"#, nip04) })
        XCTAssertEqual(other, .failed)
        let unreadable = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes,
                                       encrypt: { _, _ in "v2:not base64!" })
        XCTAssertEqual(unreadable, .failed)
    }

    /// A one-relay account (Merge Test 2026-11-04: its 10002 names only primal,
    /// which became its only read relay too) asks the indexers as well, so its
    /// own relay and an indexer answering is a base. Before, only primal was
    /// asked and Merge said "Not enough of your relays answered" forever.
    func testOneRelayAccountGetsASecondAnswerFromAnIndexer() {
        let ask = ListMerge.editLookupAsk(readRelays: ["wss://relay.primal.net"])
        XCTAssertEqual(ask, ["wss://relay.primal.net"] + RelayDraft.indexers)
        let own = ["wss://relay.primal.net"]
        let asked = Set(own + ask).count
        let answered = ReplaceableLookup(event: 100 as Int64, asked: asked, answered: 2,
                                         answeredBy: ["wss://relay.primal.net", "wss://purplepag.es"], from: ["wss://relay.primal.net"])
        guard case .list(let base) = ListMerge.editBase(answered, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("one-relay account can't merge") }
        XCTAssertEqual(base, 100)
        // Only its own relay answering is still not enough (Logen 2026-11-02 13:21Z).
        let alone = ReplaceableLookup(event: 100 as Int64, asked: asked, answered: 1,
                                      answeredBy: ["wss://relay.primal.net"], from: ["wss://relay.primal.net"])
        guard case .unknown = ListMerge.editBase(alone, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("a single answer was enough") }
    }

    func testEditLookupAskKeepsThreeReadRelaysAndDropsRepeats() {
        let ask = ListMerge.editLookupAsk(readRelays: ["wss://a.example", "wss://PURPLEPAG.es/", "wss://b.example", "wss://c.example"])
        XCTAssertEqual(ask, ["wss://a.example", "wss://PURPLEPAG.es/", "wss://b.example", "wss://user.kindpag.es"])
    }
}
