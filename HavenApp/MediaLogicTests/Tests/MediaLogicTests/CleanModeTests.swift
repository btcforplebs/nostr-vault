import XCTest
@testable import MediaLogic

/// Clean mode masks listed words, whole words only, first letter kept.
/// Android: CleanModeTest; web: clean-mode.test.mjs.
final class CleanModeTests: XCTestCase {
    /// HavenApp/ (the folder holding HavenApp/ and MediaLogicTests/).
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func shipped() throws -> Set<String> {
        let url = appRoot.appendingPathComponent("HavenApp/Resources/clean-words-en.txt")
        return CleanMode.words(fromList: try String(contentsOf: url, encoding: .utf8))
    }

    func testMaskKeepsFirstLetterLengthAndCase() {
        let words: Set<String> = ["fuck", "shit"]
        XCTAssertEqual(CleanMode.mask("Fuck this SHIT.", words: words), "F*** this S***.")
        XCTAssertEqual(CleanMode.mask("fuck", words: words), "f***")
    }

    func testWholeWordsOnly() {
        let words: Set<String> = ["ass", "cunt"]
        XCTAssertEqual(CleanMode.mask("first class assets in Scunthorpe", words: words),
                       "first class assets in Scunthorpe")
        XCTAssertEqual(CleanMode.mask("you ass!", words: words), "you a**!")
        XCTAssertEqual(CleanMode.mask("ass2", words: words), "ass2", "a digit is part of the word")
    }

    func testUnchangedTextIsReturnedAsIs() {
        let text = "nothing here 🙂\nline two"
        XCTAssertEqual(CleanMode.mask(text, words: ["fuck"]), text)
        XCTAssertEqual(CleanMode.mask("fuck", words: []), "fuck")
    }

    func testNonLetterNeighboursAndEmojiStayPut() {
        XCTAssertEqual(CleanMode.mask("🙂fuck🙂 #fuck @fuck", words: ["fuck"]), "🙂f***🙂 #f*** @f***")
    }

    /// The copy the app ships is docs/clean-words/en.txt, byte for byte
    /// (docs/clean-words/check.sh checks the same in CI).
    func testShippedCopyMatchesTheSharedList() throws {
        let copy = try Data(contentsOf: Self.appRoot.appendingPathComponent("HavenApp/Resources/clean-words-en.txt"))
        let shared = try Data(contentsOf: Self.appRoot.deletingLastPathComponent()
            .appendingPathComponent("docs/clean-words/en.txt"))
        XCTAssertEqual(copy, shared)
        XCTAssertGreaterThan(try Self.shipped().count, 100)
    }

    func testShippedListMasksTheUsualWordsAndNotEverydayOnes() throws {
        let words = try Self.shipped()
        XCTAssertEqual(CleanMode.mask("Fucking hell, what a dick move", words: words), "F****** hell, what a dick move")
    }
}
