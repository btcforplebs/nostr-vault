import XCTest
@testable import MediaLogic

final class FeedLanguageTests: XCTestCase {
    func testDetectsCommonNostrLanguages() {
        XCTAssertEqual(FeedLanguageDetector.detect("Good morning everyone, the price of bitcoin does not matter when you stack every week."), "en")
        XCTAssertEqual(FeedLanguageDetector.detect("Buenos días a todos, hoy vamos a hablar de cómo funciona la red de nostr."), "es")
        XCTAssertEqual(FeedLanguageDetector.detect("Guten Morgen zusammen, heute ist ein schöner Tag für einen Spaziergang im Park."), "de")
        XCTAssertEqual(FeedLanguageDetector.detect("あなたが遭遇している不運や災難は、実のところ、宇宙があなたに課した試練なのです。"), "ja")
        XCTAssertEqual(FeedLanguageDetector.detect("Bom dia pessoal, hoje o mercado está calmo e eu vou passear com o meu cachorro."), "pt")
    }

    func testBothChineseScriptsFoldIntoZh() {
        XCTAssertEqual(FeedLanguageDetector.baseCode("zh-Hans"), "zh")
        XCTAssertEqual(FeedLanguageDetector.baseCode("zh-Hant"), "zh")
        XCTAssertEqual(FeedLanguageDetector.baseCode("pt_BR"), "pt")
        XCTAssertNil(FeedLanguageDetector.baseCode("und"))
    }

    /// Short posts and posts that are only links can't be judged, and must
    /// not be hidden: that is most image posts.
    func testUnjudgeableNotesAreKept() {
        XCTAssertNil(FeedLanguageDetector.detect("gm"))
        XCTAssertNil(FeedLanguageDetector.detect("https://image.nostr.build/abc123def456.jpg #photography #nostr"))
        XCTAssertNil(FeedLanguageDetector.detect("nostr:npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq 🔥🔥🔥"))
        XCTAssertTrue(FeedLanguageDetector.admits(detected: nil, allowed: ["en"]))
    }

    /// The prose stripper keeps a link-heavy post from reading as English
    /// just because URLs are made of English-looking words.
    func testLinksDoNotDecideTheLanguage() {
        let post = "Guten Morgen zusammen, heute ist ein schöner Tag https://example.com/the-best-english-words-ever #bitcoin"
        XCTAssertEqual(FeedLanguageDetector.detect(post), "de")
    }

    func testAdmits() {
        XCTAssertTrue(FeedLanguageDetector.admits(detected: "es", allowed: []))
        XCTAssertTrue(FeedLanguageDetector.admits(detected: "en", allowed: ["en", "es"]))
        XCTAssertFalse(FeedLanguageDetector.admits(detected: "ja", allowed: ["en", "es"]))
    }

    func testRepostIsJudgedByTheRepostedText() {
        let inner = #"{"kind":1,"content":"Buenos días a todos, hoy vamos a hablar de cómo funciona la red de nostr.","tags":[]}"#
        let text = FeedLanguageDetector.text(of: inner, kind: 6)
        XCTAssertEqual(FeedLanguageDetector.detect(text), "es")
        XCTAssertEqual(FeedLanguageDetector.text(of: "plain", kind: 1), "plain")
        XCTAssertEqual(FeedLanguageDetector.text(of: "not json", kind: 6), "")
    }
}
