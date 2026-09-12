import XCTest
@testable import MediaLogic

/// Parser tests for the tenor.com search page.
///
/// `Fixtures/tenor-search.html` is a real capture with its 50 results cut to
/// 2 -- so a green run here means the parser reads the bytes Tenor served, not
/// the shape we imagined. The synthetic payloads below exercise the branches a
/// single capture cannot reach (an oversized GIF, a missing size, a page with
/// no payload at all).
final class TenorGifServiceTests: XCTestCase {

    private func fixtureHTML() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "tenor-search", withExtension: "html", subdirectory: "Fixtures"),
            "fixture missing from the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The real page

    func testParsesRealSearchCapture() throws {
        let gifs = try TenorGifService.parseSearchHTML(fixtureHTML())
        XCTAssertEqual(gifs.count, 2)

        let first = gifs[0]
        XCTAssertEqual(first.id, "15876389903974409249")
        XCTAssertEqual(first.description, "a cartoon character with a smile on his face and his hands up .")
        // Escaped `/` in the payload has to come back as a usable URL.
        XCTAssertEqual(first.attachURL.absoluteString,
                       "https://media1.tenor.com/m/3FREgD3-JCEAAAAC/dancing-happy-dance.gif")
        XCTAssertEqual(first.previewURL.absoluteString,
                       "https://media.tenor.com/3FREgD3-JCEAAAAM/dancing-happy-dance.gif")
        XCTAssertEqual(first.stillURL?.absoluteString,
                       "https://media.tenor.com/3FREgD3-JCEAAAAe/dancing-happy-dance.png")
        XCTAssertEqual(first.pageURL?.host, "tenor.com")
        XCTAssertEqual(first.aspectRatio, 1, accuracy: 0.0001)

        // A second, differently shaped GIF: the grid must not assume square.
        let second = gifs[1]
        XCTAssertEqual(second.id, "14112463059641248604")
        XCTAssertEqual(second.aspectRatio, 220.0 / 191.0, accuracy: 0.0001)
        XCTAssertNotEqual(second.previewURL, first.previewURL)
    }

    /// The capture's outer HTML also carries an `<img>` tag and a `<title>`.
    /// Extraction has to find the payload script, not the first script-ish
    /// thing on the page.
    func testExtractsPayloadFromSurroundingMarkup() throws {
        let payload = try XCTUnwrap(TenorGifService.extractStoreCache(fixtureHTML()))
        XCTAssertTrue(payload.hasPrefix("{"))
        XCTAssertTrue(payload.hasSuffix("}"))
        XCTAssertFalse(payload.contains("<img"))
    }

    // MARK: - Pages that give us nothing

    func testPageWithoutPayloadThrows() {
        XCTAssertThrowsError(try TenorGifService.parseSearchHTML("<html><body>nope</body></html>")) { error in
            XCTAssertEqual(error as? TenorGifService.TenorError, .payloadMissing)
        }
    }

    func testPayloadThatIsNotJSONThrows() {
        let html = "<script id=\"store-cache\">not json at all</script>"
        XCTAssertThrowsError(try TenorGifService.parseSearchHTML(html)) { error in
            XCTAssertEqual(error as? TenorGifService.TenorError, .payloadMissing)
        }
    }

    func testEmptyResultSetIsNotAnError() throws {
        let html = wrap(#"{"universal":{"search":{"nothing-low-all":{"results":[]}}}}"#)
        XCTAssertEqual(try TenorGifService.parseSearchHTML(html).count, 0)
    }

    // MARK: - Choosing what to attach

    func testPrefersFullGIFWhenItFits() throws {
        let gifs = try TenorGifService.parseSearchHTML(wrap(payload(gifSize: 1_000, mediumSize: 500, tinySize: 200)))
        XCTAssertEqual(gifs.first?.attachURL.lastPathComponent, "full.gif")
    }

    func testFallsBackToMediumWhenTheFullGIFIsOverTheCap() throws {
        let over = TenorGifService.maxGIFBytes + 1
        let gifs = try TenorGifService.parseSearchHTML(wrap(payload(gifSize: over, mediumSize: 500, tinySize: 200)))
        XCTAssertEqual(gifs.first?.attachURL.lastPathComponent, "medium.gif")
    }

    func testDropsAResultWhoseEverySizeIsOverTheCap() throws {
        let over = TenorGifService.maxGIFBytes + 1
        let gifs = try TenorGifService.parseSearchHTML(wrap(payload(gifSize: over, mediumSize: over, tinySize: over)))
        XCTAssertTrue(gifs.isEmpty, "an unattachable GIF should never reach the grid")
    }

    /// An unknown size is not a small size. A format with no `size` is skipped
    /// for the attach slot rather than gambled on.
    func testFormatWithNoSizeIsNotChosenToAttach() throws {
        let gifs = try TenorGifService.parseSearchHTML(wrap(payload(gifSize: nil, mediumSize: 500, tinySize: 200)))
        XCTAssertEqual(gifs.first?.attachURL.lastPathComponent, "medium.gif")
    }

    /// The preview slot has no cap -- it is display only -- so it keeps taking
    /// the small format even when the attach slot had to move down.
    func testPreviewStaysOnTheSmallFormat() throws {
        let over = TenorGifService.maxGIFBytes + 1
        let gifs = try TenorGifService.parseSearchHTML(wrap(payload(gifSize: over, mediumSize: 500, tinySize: 200)))
        XCTAssertEqual(gifs.first?.previewURL.lastPathComponent, "tiny.gif")
    }

    func testDeduplicatesByID() throws {
        let one = payload(gifSize: 1_000, mediumSize: 500, tinySize: 200)
        let html = wrap("{\"universal\":{\"search\":{\"a-low-all\":{\"results\":[\(resultsOf(one)),\(resultsOf(one))]}}}}")
        XCTAssertEqual(try TenorGifService.parseSearchHTML(html).count, 1)
    }

    // MARK: - Shape

    func testAspectRatioIsClampedAtBothEnds() {
        XCTAssertEqual(TenorGifService.aspectRatio(from: [240, 240]), 1, accuracy: 0.0001)
        XCTAssertEqual(TenorGifService.aspectRatio(from: [180, 900]), TenorGifService.minAspectRatio, accuracy: 0.0001)
        XCTAssertEqual(TenorGifService.aspectRatio(from: [900, 180]), TenorGifService.maxAspectRatio, accuracy: 0.0001)
    }

    func testAspectRatioFallsBackToSquareOnNonsense() {
        XCTAssertEqual(TenorGifService.aspectRatio(from: []), 1, accuracy: 0.0001)
        XCTAssertEqual(TenorGifService.aspectRatio(from: [0, 100]), 1, accuracy: 0.0001)
        XCTAssertEqual(TenorGifService.aspectRatio(from: [100]), 1, accuracy: 0.0001)
    }

    // MARK: - Search URL

    func testSearchURLIsASlugNotAQueryString() throws {
        let url = try XCTUnwrap(TenorGifService.searchURL(for: "happy"))
        XCTAssertEqual(url.absoluteString, "https://tenor.com/search/happy-gifs")
    }

    func testSearchURLEncodesTheWholeQueryAsOneSegment() throws {
        XCTAssertEqual(TenorGifService.searchURL(for: "hello world")?.absoluteString,
                       "https://tenor.com/search/hello%20world-gifs")
        // A slash would otherwise cut the route short and land on a different page.
        XCTAssertEqual(TenorGifService.searchURL(for: "ac/dc")?.absoluteString,
                       "https://tenor.com/search/ac%2Fdc-gifs")
        XCTAssertEqual(TenorGifService.searchURL(for: "c'mon?")?.absoluteString,
                       "https://tenor.com/search/c%27mon%3F-gifs")
    }

    func testSearchURLIsNilForAnEmptyQuery() {
        XCTAssertNil(TenorGifService.searchURL(for: ""))
        XCTAssertNil(TenorGifService.searchURL(for: "   \n "))
    }

    // MARK: - Helpers

    private func wrap(_ json: String) -> String {
        "<html><head><title>x</title></head><body><img src=\"a.gif\">" +
        "<script id=\"store-cache\" type=\"text/x-cache\">\(json)</script></body></html>"
    }

    private func resultsOf(_ payloadJSON: String) -> String {
        // `payload` already produces the full universal wrapper; pull the one
        // result object back out so it can be repeated.
        let start = payloadJSON.range(of: "[")!.upperBound
        let end = payloadJSON.range(of: "]", options: .backwards)!.lowerBound
        return String(payloadJSON[start..<end])
    }

    private func payload(gifSize: Int?, mediumSize: Int?, tinySize: Int?) -> String {
        func format(_ name: String, _ file: String, _ size: Int?) -> String {
            let sizeField = size.map { ",\"size\":\($0)" } ?? ""
            return "\"\(name)\":{\"url\":\"https:\\u002F\\u002Fmedia.tenor.com\\u002Fx\\u002F\(file)\",\"dims\":[240,240]\(sizeField)}"
        }
        let formats = [
            format("gif", "full.gif", gifSize),
            format("mediumgif", "medium.gif", mediumSize),
            format("tinygif", "tiny.gif", tinySize),
        ].joined(separator: ",")
        let result = "{\"id\":\"1\",\"content_description\":\"a test gif\",\"itemurl\":\"https:\\u002F\\u002Ftenor.com\\u002Fview\\u002F1\",\"media_formats\":{\(formats)}}"
        return "{\"universal\":{\"search\":{\"a-low-all\":{\"results\":[\(result)]}}}}"
    }
}
