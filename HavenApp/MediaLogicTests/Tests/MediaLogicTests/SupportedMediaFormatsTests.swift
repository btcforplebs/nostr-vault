import XCTest
@testable import MediaLogic

/// Every media type the app claims to support must classify the same way from
/// its extension and from its MIME type, and round-trip MIME -> extension.
final class SupportedMediaFormatsTests: XCTestCase {

    func testEveryEntryClassifiesConsistentlyByExtensionAndMime() {
        for entry in SupportedMediaFormats.all {
            XCTAssertEqual(SupportedMediaFormats.category(forExtension: entry.ext), entry.category, entry.ext)
            XCTAssertEqual(SupportedMediaFormats.category(forExtension: entry.ext.uppercased()), entry.category, entry.ext)
            XCTAssertEqual(SupportedMediaFormats.category(forMime: entry.mime), entry.category, entry.mime)
            XCTAssertEqual(SupportedMediaFormats.mime(forExtension: entry.ext), entry.mime, entry.ext)
            XCTAssertNotNil(SupportedMediaFormats.extension(forMime: entry.mime), entry.mime)
        }
    }

    func testVideoContainersTheRelayServesAreAllVideo() {
        // Mirrors haven-go blossomExtTypes: what the relay labels as video the
        // app must treat as video, or the media tab shows a document icon.
        for ext in ["mp4", "m4v", "mov", "webm"] {
            XCTAssertTrue(SupportedMediaFormats.videoExtensions.contains(ext), ext)
            XCTAssertTrue(URL(string: "https://127.0.0.1:3355/\(String(repeating: "a", count: 64)).\(ext)")!.isVideo, ext)
        }
        for ext in ["mp3", "m4a", "wav"] {
            XCTAssertTrue(SupportedMediaFormats.audioExtensions.contains(ext), ext)
        }
        for ext in ["gif", "jpg", "jpeg", "png", "webp", "avif"] {
            XCTAssertTrue(SupportedMediaFormats.imageOrGifExtensions.contains(ext), ext)
        }
    }

    func testMimeParametersAndAliasesResolve() {
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "video/mp4; codecs=avc1"), "mp4")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "VIDEO/QUICKTIME"), "mov")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "video/mov"), "mov")
        XCTAssertEqual(SupportedMediaFormats.extension(forMime: "audio/x-m4a"), "m4a")
        XCTAssertNil(SupportedMediaFormats.extension(forMime: "application/octet-stream"))
        XCTAssertNil(SupportedMediaFormats.category(forMime: "application/octet-stream"))
    }

    func testExtensionlessBlossomHashCountsAsImageCandidateOnly() {
        let hash = String(repeating: "f", count: 64)
        let bare = URL(string: "https://127.0.0.1:3355/\(hash)")!
        XCTAssertTrue(bare.isImage, "bare hash is a media candidate until sniffed")
        XCTAssertFalse(bare.isVideo)
        XCTAssertFalse(bare.isGIF)
    }

    func testMediaURLRegexMatchesExtensionAndBlossomForms() throws {
        let regex = try XCTUnwrap(SupportedMediaFormats.mediaURLRegex)
        let hash = String(repeating: "0", count: 64)
        let text = "see https://a.b/c.MOV and https://x.y/\(hash) plus https://x.y/blossom/\(hash) and https://x.y/page.html"
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        XCTAssertEqual(matches.count, 3)
    }

    // MARK: Media or web page (the Media grid drew njump.me links as broken images)

    private func urls(_ text: String) -> [String] {
        SupportedMediaFormats.mediaURLs(in: text).map(\.absoluteString)
    }

    func testNostrWebClientHexLinksAreNotMedia() {
        // Shape of real notes: njump.me serves the event page at /<event id>.
        let id = "84abd19a647d5aab47010926d258d0294e108727495df5de996f5baab3c8949a"
        XCTAssertEqual(urls("read https://njump.me/\(id)"), [])
        XCTAssertEqual(urls("https://www.primal.net/\(id)"), [])
        XCTAssertFalse(URL(string: "https://njump.me/\(id)")!.isImage)
        XCTAssertFalse(SupportedMediaFormats.isMediaURL(URL(string: "https://njump.me/\(id)")!))
        // A real Blossom server under a gateway's domain still counts.
        XCTAssertEqual(urls("https://blossom.primal.net/\(id)"), ["https://blossom.primal.net/\(id)"])
        XCTAssertEqual(urls("https://cdn.example.com/\(id)"), ["https://cdn.example.com/\(id)"])
    }

    func testBech32WebLinksAreNotMedia() {
        let text = "https://njump.me/nevent1qqsxyz https://njump.me/note1abc https://njump.me/naddr1qq https://njump.me/npub1abc.rss"
        XCTAssertEqual(urls(text), [])
    }

    func testExtensionMustEndTheURL() {
        XCTAssertEqual(urls("https://www.avid.com/x"), [], "avid.com is not .avi")
        XCTAssertEqual(urls("https://blog.pngtree.com/p"), [])
        XCTAssertEqual(urls("https://njump.me/naddr1qq.mp4ish"), [])
        XCTAssertEqual(urls("https://example.mov"), [], ".mov the TLD is a site")
        XCTAssertEqual(urls("https://www.avid.com/clip.mp4"), ["https://www.avid.com/clip.mp4"])
        XCTAssertEqual(urls("look https://x.com/a.JPG."), ["https://x.com/a.JPG"])
        XCTAssertEqual(urls("(https://x.com/a.png)"), ["https://x.com/a.png"])
        XCTAssertEqual(urls("https://x.com/a.jpg?w=1"), ["https://x.com/a.jpg?w=1"])
        XCTAssertEqual(urls("https://x.com/a.jpg-thumb.webp"), ["https://x.com/a.jpg-thumb.webp"])
        XCTAssertEqual(urls("https://image.nostr.build/a.jpg https://njump.me/note1abc"), ["https://image.nostr.build/a.jpg"])
    }

    func testImetaKeepsUploadsDropsWebPages() {
        let id = String(repeating: "a", count: 64)
        XCTAssertTrue(SupportedMediaFormats.isImetaMediaURL(URL(string: "https://cdn.example.com/upload")!))
        XCTAssertTrue(SupportedMediaFormats.isImetaMediaURL(URL(string: "https://njump.me/a.png")!))
        XCTAssertFalse(SupportedMediaFormats.isImetaMediaURL(URL(string: "https://njump.me/\(id)")!))
    }
}
