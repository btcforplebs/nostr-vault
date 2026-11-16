import XCTest
@testable import MediaLogic

/// Blocking privately: the person goes in the mute list's encrypted part.
/// Android: ListMergePrivateAddTest.
final class ListMergePrivateAddTests: XCTestCase {
    /// Stand-in for NIP-44/NIP-04 to self: NIP-04 output carries "?iv=" as the real one does.
    private static func seal(_ text: String, _ nip04: Bool) -> String {
        nip04 ? Data(text.utf8).base64EncodedString() + "?iv=AAAA" : "v2:" + Data(text.utf8).base64EncodedString()
    }

    private static func open(_ text: String, _ nip04: Bool) throws -> String {
        let body = nip04 ? String(text.prefix { $0 != "?" }) : String(text.dropFirst(3))
        guard let data = Data(base64Encoded: body), let out = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return out
    }

    private func block(_ content: String, _ add: [String], schemes: inout [Bool],
                       decrypt: ((String, Bool) throws -> String)? = nil,
                       encrypt: ((String, Bool) throws -> String)? = nil) async -> ListMerge.PrivateEdit {
        var used: [Bool] = []
        let result = await ListMerge.addingPrivate(content: content, add: add,
            decrypt: { text, nip04 in
                used.append(nip04)
                return try (decrypt ?? Self.open)(text, nip04)
            },
            encrypt: { text, nip04 in
                used.append(nip04)
                return try (encrypt ?? Self.seal)(text, nip04)
            })
        schemes = used
        return result
    }

    private static let privatePart = #"[["p","aaa"],["p","bbb","wss://r.example/","pet"],["word","spoiler"],["e","thread1"]]"#

    func testPrivateBlockKeepsEverythingElseInTheNip44Part() async throws {
        var schemes: [Bool] = []
        let result = await block(Self.seal(Self.privatePart, false), ["ccc"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertFalse(MuteList.isNip04(content))
        XCTAssertEqual(try MuteList.privateTags(fromJSON: Self.open(content, false)),
                       [["p", "aaa"], ["p", "bbb", "wss://r.example/", "pet"], ["word", "spoiler"], ["e", "thread1"], ["p", "ccc"]])
        XCTAssertEqual(schemes, [false, false, false], "opened, encrypted, opened again to check")
    }

    func testPrivateBlockKeepsANip04PartNip04() async throws {
        var schemes: [Bool] = []
        let result = await block(Self.seal(Self.privatePart, true), ["ccc"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertTrue(MuteList.isNip04(content))
        XCTAssertTrue(try MuteList.privateTags(fromJSON: Self.open(content, true)).contains(["p", "ccc"]))
        XCTAssertEqual(schemes, [true, true, true])
    }

    func testAListWithNoPrivatePartStartsANip44One() async throws {
        var schemes: [Bool] = []
        let result = await block("  ", ["ccc"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        XCTAssertFalse(MuteList.isNip04(content))
        XCTAssertEqual(try Self.open(content, false), #"[["p","ccc"]]"#)
        XCTAssertEqual(schemes, [false, false], "encrypted, opened again to check")
    }

    func testSomeoneAlreadyInThePrivatePartIsNotAddedTwice() async throws {
        var schemes: [Bool] = []
        let result = await block(Self.seal(Self.privatePart, false), ["AAA"], schemes: &schemes)
        guard case .content(let content) = result else { return XCTFail("not published: \(result)") }
        let tags = try MuteList.privateTags(fromJSON: Self.open(content, false))
        XCTAssertEqual(tags.filter { $0.first == "p" && $0[1].lowercased() == "aaa" }.count, 1)
    }

    /// A signer that won't decrypt must not publish a new part over one it never read.
    func testAPrivatePartThisDeviceCantOpenIsNotReplaced() async {
        var schemes: [Bool] = []
        let result = await block("v2:not base64!", ["ccc"], schemes: &schemes)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(schemes, [false], "opened, never encrypted")
    }

    func testAPrivatePartARewriteWouldLoseIsNotReplaced() async {
        let odd = Self.seal(#"[["p","aaa",null],{"x":"y"}]"#, false)
        var schemes: [Bool] = []
        let result = await block(odd, ["ccc"], schemes: &schemes)
        XCTAssertEqual(result, .failed)
        XCTAssertNil(ListMerge.privateAdded(plaintext: #"{"p":"aaa"}"#, add: ["ccc"]))
    }

    func testNotPublishedWhenTheSignerCantEncryptOrEchoesThePlaintext() async {
        var schemes: [Bool] = []
        let refused = await block(Self.seal(Self.privatePart, false), ["ccc"], schemes: &schemes,
                                  encrypt: { _, _ in throw URLError(.userCancelledAuthentication) })
        XCTAssertEqual(refused, .failed)
        let echoed = await block("", ["ccc"], schemes: &schemes, encrypt: { text, _ in text })
        XCTAssertEqual(echoed, .failed)
        // NIP-04 asked, NIP-44 given back: the scheme would change under other apps.
        let swapped = await block(Self.seal(Self.privatePart, true), ["ccc"], schemes: &schemes,
                                  encrypt: { text, _ in Self.seal(text, false) })
        XCTAssertEqual(swapped, .failed)
    }

    func testNobodyToAddPublishesNothing() async {
        var schemes: [Bool] = []
        let result = await block(Self.seal(Self.privatePart, false), [], schemes: &schemes)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(schemes, [])
    }
}
