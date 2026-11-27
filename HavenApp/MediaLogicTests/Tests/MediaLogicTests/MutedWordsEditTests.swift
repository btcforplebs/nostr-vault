import XCTest
@testable import MediaLogic

/// Settings › Muted words: only the named `word` entries change on a kind
/// 10000 other clients edit too. Android: MutedWordsEditTest.
final class MutedWordsEditTests: XCTestCase {
    private static func seal(_ text: String, _ nip04: Bool) -> String {
        nip04 ? Data(text.utf8).base64EncodedString() + "?iv=AAAA" : "v2:" + Data(text.utf8).base64EncodedString()
    }

    private static func open(_ text: String, _ nip04: Bool) throws -> String {
        let body = nip04 ? String(text.prefix { $0 != "?" }) : String(text.dropFirst(3))
        guard let data = Data(base64Encoded: body), let out = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return out
    }

    private static func part(_ tags: [[String]], nip04: Bool = false) -> String {
        let data = try! JSONSerialization.data(withJSONObject: tags, options: [.withoutEscapingSlashes])
        return seal(String(data: data, encoding: .utf8)!, nip04)
    }

    private func run(tags: [[String]] = [], content: String = "", add: [String] = [], remove: [String] = [],
                     publicly: Bool = false, known: Set<String> = [],
                     decrypt: ((String, Bool) throws -> String)? = nil,
                     encrypt: ((String, Bool) throws -> String)? = nil) async -> Result<MutedWordsEdit.Result, MutedWordsEdit.Failure> {
        await MutedWordsEdit.apply(tags: tags, content: content, add: add, remove: remove, publicly: publicly,
                                   knownPrivate: known,
                                   decrypt: { try (decrypt ?? Self.open)($0, $1) },
                                   encrypt: { try (encrypt ?? Self.seal)($0, $1) })
    }

    private func privateTags(_ content: String) throws -> [[String]] {
        try MuteList.privateTags(fromJSON: Self.open(content, MuteList.isNip04(content)))
    }

    func testNormalizedLowercasesTrimsAndJoinsSpaces() {
        XCTAssertEqual(MutedWordsEdit.normalized("  Big\n  Spoiler "), "big spoiler")
        XCTAssertNil(MutedWordsEdit.normalized("   "))
        XCTAssertNil(MutedWordsEdit.normalized("#"))
        XCTAssertNil(MutedWordsEdit.normalized(String(repeating: "a", count: MutedWordsEdit.maxLength + 1)))
    }

    func testPrivateAddStartsANip44PartAndKeepsEveryPublicTag() async throws {
        let tags = [["p", "aa"], ["t", "nsfw"], ["word", "public"], ["e", "ee"]]
        guard case .success(let out) = await run(tags: tags, add: ["Spoiler"]) else { return XCTFail() }
        XCTAssertEqual(out.tags, tags)
        XCTAssertFalse(MuteList.isNip04(out.content))
        XCTAssertEqual(try privateTags(out.content), [["word", "spoiler"]])
    }

    func testPrivateAddKeepsTheRestOfThePartAndItsScheme() async throws {
        let content = Self.part([["p", "bb"], ["word", "old"], ["x", "1", "2"]], nip04: true)
        guard case .success(let out) = await run(content: content, add: ["new"]) else { return XCTFail() }
        XCTAssertTrue(MuteList.isNip04(out.content))
        XCTAssertEqual(try privateTags(out.content), [["p", "bb"], ["word", "old"], ["x", "1", "2"], ["word", "new"]])
    }

    func testPublicAddGoesInTagsAndLeavesThePartAlone() async {
        let content = Self.part([["p", "bb"]])
        guard case .success(let out) = await run(tags: [["p", "aa"]], content: content, add: ["Word"], publicly: true)
        else { return XCTFail() }
        XCTAssertEqual(out.tags, [["p", "aa"], ["word", "word"]])
        XCTAssertEqual(out.content, content, "an unchanged part is not encrypted again")
    }

    func testMakingAPrivateWordPublicMovesIt() async throws {
        let content = Self.part([["word", "spoiler"], ["p", "bb"]])
        guard case .success(let out) = await run(content: content, add: ["spoiler"], publicly: true, known: ["spoiler"])
        else { return XCTFail() }
        XCTAssertEqual(out.tags, [["word", "spoiler"]])
        XCTAssertEqual(try privateTags(out.content), [["p", "bb"]])
    }

    func testMakingAPublicWordPrivateMovesIt() async throws {
        guard case .success(let out) = await run(tags: [["word", "spoiler"], ["p", "aa"]], add: ["spoiler"])
        else { return XCTFail() }
        XCTAssertEqual(out.tags, [["p", "aa"]])
        XCTAssertEqual(try privateTags(out.content), [["word", "spoiler"]])
    }

    func testRemoveTakesTheWordOutOfBothSidesInAnyCase() async throws {
        let content = Self.part([["word", "Spoiler"], ["word", "keep"]])
        guard case .success(let out) = await run(tags: [["word", "SPOILER "], ["t", "x"]], content: content,
                                                 remove: ["spoiler"], known: ["spoiler"]) else { return XCTFail() }
        XCTAssertEqual(out.tags, [["t", "x"]])
        XCTAssertEqual(try privateTags(out.content), [["word", "keep"]])
    }

    func testPrivateAddFailsWhenThePartCantBeOpened() async {
        let result = await run(content: Self.part([["p", "bb"]]), add: ["w"],
                               decrypt: { _, _ in throw URLError(.userAuthenticationRequired) })
        XCTAssertEqual(result, .failure(.privatePart))
    }

    func testRemovingAKnownPrivateWordFailsWhenThePartCantBeOpened() async {
        let result = await run(tags: [["word", "w"]], content: Self.part([["word", "w"]]), remove: ["w"], known: ["w"],
                               decrypt: { _, _ in throw URLError(.userAuthenticationRequired) })
        XCTAssertEqual(result, .failure(.privatePart))
    }

    func testRemovingAPublicWordStillWorksWhenThePartCantBeOpened() async {
        let content = Self.part([["p", "bb"]])
        let result = await run(tags: [["word", "w"], ["p", "aa"]], content: content, remove: ["w"],
                               decrypt: { _, _ in throw URLError(.userAuthenticationRequired) })
        XCTAssertEqual(result, .success(.init(tags: [["p", "aa"]], content: content)))
    }

    func testAPartThatIsNotAStringListIsNeverRewritten() async {
        let content = Self.seal(#"[["p","bb"],["word",1]]"#, false)
        let result = await run(content: content, add: ["w"])
        XCTAssertEqual(result, .failure(.privatePart))
    }

    func testASignerThatEchoesThePlaintextIsRefused() async {
        let result = await run(add: ["w"], encrypt: { text, _ in text })
        XCTAssertEqual(result, .failure(.privatePart))
    }

    func testASignerThatSwitchesSchemeIsRefused() async {
        let result = await run(content: Self.part([["p", "bb"]], nip04: true), add: ["w"],
                               encrypt: { text, _ in Self.seal(text, false) })
        XCTAssertEqual(result, .failure(.privatePart))
    }

    func testNothingToDo() async {
        let result = await run(add: ["  "])
        XCTAssertEqual(result, .failure(.nothingToDo))
    }

    func testMuteListSaysWhichSideAWordIsOn() {
        let list = MuteList(publicTags: [["word", "Pub"], ["word", "both"]], privateTags: [["word", "priv"], ["word", "both"]])
        XCTAssertEqual(list.publicWords, ["pub", "both"])
        XCTAssertEqual(list.privateWords, ["priv", "both"])
        XCTAssertEqual(Set(list.words), ["pub", "both", "priv"])
    }
}
