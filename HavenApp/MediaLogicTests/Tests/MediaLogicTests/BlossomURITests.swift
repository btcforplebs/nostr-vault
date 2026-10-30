import XCTest
import CryptoKit
@testable import MediaLogic

/// BUD-10 `blossom:` links: what the note parser draws as media, which
/// servers a reader asks, and which bytes it keeps.
final class BlossomURITests: XCTestCase {
    private let sha = "d819b922fbbf3a47e606dab12a6c316b9a0445ff4aa69d749d638ce83884cf1c"
    private let author = "1ec454734dcbf6fe54901ce25c0c7c6bca5edd89443416761fadc321d38df139"

    /// Laan Tungir's test note, 2026-10-30, as it reached nos.lol.
    private var testNote: String {
        "This is a test of BUD-10. Can you see this image? What client are you using?\n"
            + "blossom:\(sha).jpg?xs=blossom.laantungir.net&xs=cdn.satellite.earth&xs=blossom.primal.net"
            + "&as=\(author)&sz=117475"
    }

    // MARK: - Parser

    func testTheTestNotesLinkParses() throws {
        let url = try XCTUnwrap(SupportedMediaFormats.mediaURLs(in: testNote).first)
        let uri = try XCTUnwrap(BlossomURI(url))
        XCTAssertEqual(uri.sha256, sha)
        XCTAssertEqual(uri.ext, "jpg")
        XCTAssertEqual(uri.servers.map(\.absoluteString),
                       ["https://blossom.laantungir.net", "https://cdn.satellite.earth", "https://blossom.primal.net"])
        XCTAssertEqual(uri.author, author)
        XCTAssertEqual(uri.size, 117475)
        XCTAssertTrue(url.isImage)
    }

    func testTheLinkIsTheWholeMediaURLSoTheTextDropsAllOfIt() {
        let urls = SupportedMediaFormats.mediaURLs(in: testNote)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(testNote.hasSuffix(urls[0].absoluteString))
    }

    func testABareLinkWithNoHintsIsStillMedia() throws {
        let url = try XCTUnwrap(SupportedMediaFormats.mediaURLs(in: "look blossom:\(sha.uppercased()).MP4 ok").first)
        let uri = try XCTUnwrap(BlossomURI(url))
        XCTAssertEqual(uri.sha256, sha)
        XCTAssertEqual(uri.ext, "mp4")
        XCTAssertEqual(uri.servers, [])
        XCTAssertNil(uri.author)
        XCTAssertNil(uri.size)
        XCTAssertTrue(url.isVideo)
    }

    func testANonMediaExtensionStaysText() {
        XCTAssertEqual(SupportedMediaFormats.mediaURLs(in: "blossom:\(sha).pdf?xs=cdn.example.com"), [])
    }

    func testMalformedLinksAreNotMedia() {
        for text in ["blossom:\(sha.dropLast()).jpg", "blossom:\(sha)", "blossom:zz\(sha.dropFirst(2)).jpg", "blossom://\(sha).jpg"] {
            XCTAssertEqual(SupportedMediaFormats.mediaURLs(in: text), [], text)
        }
        XCTAssertNil(BlossomURI(URL(string: "https://cdn.example.com/\(sha).jpg")!))
        XCTAssertNil(BlossomURI(URL(string: "blossom:\(sha)")!))
    }

    func testServerHintsAreHTTPSBasesOnceEach() throws {
        let link = "blossom:\(sha).png?xs=https://a.example/&xs=a.example&xs=http://plain.example"
            + "&xs=ftp://x.example&xs=&xs=b.example/path&xs=c.example?x=1"
        let uri = try XCTUnwrap(BlossomURI(URL(string: link)!))
        XCTAssertEqual(uri.servers.map(\.absoluteString), ["https://a.example", "https://b.example/path"])
    }

    func testAnNpubAuthorIsReadAsHexAndJunkIsDropped() throws {
        let npub = try XCTUnwrap(Bech32.encode(hrp: "npub", data: Data(hexString: author)))
        XCTAssertEqual(BlossomURI(URL(string: "blossom:\(sha).jpg?as=\(npub)")!)?.author, author)
        XCTAssertNil(BlossomURI(URL(string: "blossom:\(sha).jpg?as=bob&sz=-4")!)?.author)
        XCTAssertNil(BlossomURI(URL(string: "blossom:\(sha).jpg?sz=-4")!)?.size)
    }

    // MARK: - Where to ask

    func testCandidatesGoLinkThenAuthorThenOursOnceEach() throws {
        let uri = try XCTUnwrap(BlossomURI(URL(string: "blossom:\(sha).jpg?xs=one.example&xs=two.example")!))
        let urls = uri.candidates(
            authorServers: ["https://two.example/", "https://author.example", "fipsmesh://npub1abc/", "http://old.example"],
            fallbackServers: ["https://blossom.primal.net", "one.example"]
        )
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://one.example/\(sha).jpg",
            "https://two.example/\(sha).jpg",
            "https://author.example/\(sha).jpg",
            "https://blossom.primal.net/\(sha).jpg",
        ])
    }

    // MARK: - Which bytes count

    func testOnlyBytesThatHashToTheLinkMatch() throws {
        let bytes = Data("the photo".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let uri = try XCTUnwrap(BlossomURI(URL(string: "blossom:\(hash).jpg")!))
        XCTAssertTrue(uri.matches(bytes))
        XCTAssertFalse(uri.matches(Data("the photo, swapped by a server".utf8)))
        XCTAssertFalse(uri.matches(Data()))
    }

    func testOnlyAFileThatHashesToTheLinkMatches() throws {
        // Over one 1 MB read, so the pieces are joined in order.
        let bytes = Data((0..<(3 << 19)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let uri = try XCTUnwrap(BlossomURI(URL(string: "blossom:\(hash).mp4")!))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good"), bad = dir.appendingPathComponent("bad")
        try bytes.write(to: good)
        var swapped = bytes; swapped[swapped.count - 1] ^= 1
        try swapped.write(to: bad)
        XCTAssertTrue(uri.matches(file: good))
        XCTAssertFalse(uri.matches(file: bad))
        XCTAssertFalse(uri.matches(file: dir.appendingPathComponent("missing")))
    }

    func testIsMediaURLAcceptsOnlyMediaBlossomLinks() {
        XCTAssertTrue(SupportedMediaFormats.isMediaURL(URL(string: "blossom:\(sha).webp")!))
        XCTAssertFalse(SupportedMediaFormats.isMediaURL(URL(string: "blossom:\(sha).pdf")!))
    }
}

private extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
