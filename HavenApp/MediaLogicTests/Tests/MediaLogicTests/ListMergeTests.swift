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
        let fetched = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1)
        guard case .list(let newest) = ListMerge.editBase(fetched, held: 200, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(newest, 200)
        guard case .list(let fetchedOnly) = ListMerge.editBase(fetched, held: nil, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(fetchedOnly, 100)
    }

    func testEditBaseIsUnknownWhenTheFetchFails() {
        let nobody = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 0)
        guard case .unknown = ListMerge.editBase(nobody, held: 200, createdAt: { $0 }) else { return XCTFail("published on a failed fetch") }
        let some = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 2)
        guard case .unknown = ListMerge.editBase(some, held: nil, createdAt: { $0 }) else { return XCTFail("published with a relay unanswered") }
        let all = ReplaceableLookup<Int64>(event: nil, asked: 3, answered: 3)
        guard case .none = ListMerge.editBase(all, held: nil, createdAt: { $0 }) else { return XCTFail("no list anywhere should be none") }
    }

    func testEditBaseIsUnknownOnACopyNoOwnRelayVouchesFor() {
        let own = ["wss://mine.example"]
        // Only purplepag.es answered; the user's relay timed out.
        let stale = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                      answeredBy: ["wss://purplepag.es"], from: ["wss://purplepag.es"])
        guard case .unknown = ListMerge.editBase(stale, held: 50, own: own, createdAt: { $0 }) else { return XCTFail("built on a stale copy") }
        // The user's relay sent it.
        let fromMine = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 1,
                                         answeredBy: ["wss://mine.example/"], from: ["wss://mine.example/"])
        guard case .list(let list) = ListMerge.editBase(fromMine, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
        XCTAssertEqual(list, 100)
        // The user's relay answered with an older copy; the newer one counts.
        let newerElsewhere = ReplaceableLookup(event: 100 as Int64, asked: 3, answered: 2,
                                               answeredBy: ["wss://mine.example", "wss://purplepag.es"], from: ["wss://purplepag.es"])
        guard case .list = ListMerge.editBase(newerElsewhere, held: nil, own: own, createdAt: { $0 }) else { return XCTFail("no list") }
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

    private func unblock(_ content: String, _ remove: [String], schemes: inout [Bool],
                         encryptFails: Bool = false) async -> ListMerge.PrivateEdit {
        var used: [Bool] = []
        let result = await ListMerge.removingPrivate(content: content, remove: remove,
            decrypt: { used.append($1); return try Self.open($0, $1) },
            encrypt: { text, nip04 in
                used.append(nip04)
                if encryptFails { throw URLError(.userCancelledAuthentication) }
                return Self.seal(text, nip04)
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
        XCTAssertEqual(schemes, [false, false])
    }

    func testUnblockKeepsANip04PartNip04() async throws {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, true), ["bbb"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertTrue(MuteList.isNip04(content))
        XCTAssertEqual(try MuteList.privateTags(fromJSON: Self.open(content, true)),
                       [["p", "aaa"], ["word", "spoiler"], ["e", "thread1"]])
        XCTAssertEqual(schemes, [true, true])
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
        let block = await unblock(Self.seal(Self.privatePart, false), [], schemes: &schemes)
        XCTAssertEqual(block, .content(Self.seal(Self.privatePart, false)))
        XCTAssertEqual(schemes, [])
        let empty = await unblock("", ["aaa"], schemes: &schemes)
        XCTAssertEqual(empty, .content(""))
        XCTAssertEqual(schemes, [])
    }

    func testAPrivatePartThisDeviceCantOpenIsKept() async {
        var schemes: [Bool] = []
        let result = await unblock("v2:not base64!", ["aaa"], schemes: &schemes)
        XCTAssertEqual(result, .content("v2:not base64!"))
    }

    func testAPrivatePartARewriteWouldLoseIsKept() async {
        let odd = Self.seal(#"[["p","aaa"],["p","bbb",1],{"x":"y"}]"#, false)
        var schemes: [Bool] = []
        let result = await unblock(odd, ["aaa"], schemes: &schemes)
        XCTAssertEqual(result, .content(odd))
        XCTAssertEqual(schemes, [false], "opened, never encrypted again")
        XCTAssertNil(ListMerge.privateRemoved(plaintext: #"{"p":"aaa"}"#, remove: ["aaa"]))
    }

    func testUnblockIsNotPublishedWhenThePrivatePartCantBeEncryptedAgain() async {
        var schemes: [Bool] = []
        let result = await unblock(Self.seal(Self.privatePart, false), ["aaa"], schemes: &schemes, encryptFails: true)
        XCTAssertEqual(result, .failed)
    }
}
