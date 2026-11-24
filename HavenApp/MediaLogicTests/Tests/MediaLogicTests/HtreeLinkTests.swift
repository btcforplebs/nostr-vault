import XCTest
import CryptoKit
@testable import MediaLogic

/// `htree://` (Iris hashtree) photo links, phase 1: one CHK blob up to 2 MiB.
/// The fixture is the real note that started this (MaxisClub b467f19b…),
/// hashtree's own CHK interop vectors and small end-to-end blobs, shared with
/// web (test/htree.test.mjs) and Android: Fixtures/Htree/HTREE_VECTORS.json,
/// a copy of docs/HTREE_VECTORS.json. HTREE_REAL_BLOB=<path to the blob from
/// upload.iris.to> also opens the real 948 KB photo.
final class HtreeLinkTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Note: Decodable {
            struct Event: Decodable { let content: String; let pubkey: String }
            let event: Event
            let link, blobHash, key, plainSha256, name, ext: String
            let plainBytes: Int
        }
        struct Chk: Decodable { let name, plain, key, ciphertext: String }
        struct E2E: Decodable { let name, link, blobHash, plainSha256, blob: String; let plain, mime: String?; let show: Bool }
        struct Link: Decodable { let name, link: String }
        let note: Note
        let chk: [Chk]
        let e2e: [E2E]
        let notShown: [Link]
    }

    private func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "HTREE_VECTORS", withExtension: "json", subdirectory: "Fixtures/Htree"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func unhex(_ s: String) -> Data {
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func testTheFixtureNotesLinkIsAPhotoWithItsPlainHash() throws {
        let v = try vectors()
        let url = try XCTUnwrap(SupportedMediaFormats.mediaURLs(in: v.note.event.content).first)
        XCTAssertEqual(url.absoluteString, v.note.link)
        let link = try XCTUnwrap(HtreeLink(url))
        XCTAssertEqual(link.blobHash, v.note.blobHash)
        XCTAssertEqual(link.sha256, v.note.plainSha256, "the vault keeps it under the hash the link carries")
        XCTAssertEqual("01" + hex(link.chk), v.note.key)
        XCTAssertEqual(link.name, v.note.name)
        XCTAssertEqual(link.ext, v.note.ext)
        XCTAssertTrue(url.isImage)
        XCTAssertFalse(url.isVideo)
    }

    func testTheLinkLeavesTheNoteText() throws {
        let v = try vectors()
        let urls = SupportedMediaFormats.mediaURLs(in: v.note.event.content)
        XCTAssertEqual(NoteURLs.strip(urls, from: v.note.event.content), "1692. Myself")
    }

    func testHashtreeCHKVectorsDecryptAndAWrongKeyGivesNothing() throws {
        for c in try vectors().chk {
            XCTAssertEqual(HtreeLink.decryptChk(unhex(c.ciphertext), key: unhex(c.key)).map(hex), c.plain, c.name)
            XCTAssertNil(HtreeLink.decryptChk(unhex(c.ciphertext), key: Data(count: 32)), c.name)
        }
    }

    func testOnlyCHKLinksAreRead() throws {
        for l in try vectors().notShown {
            let url = try XCTUnwrap(URL(string: l.link))
            XCTAssertNil(HtreeLink(url), l.name)
            XCTAssertFalse(SupportedMediaFormats.isMediaURL(url), l.name)
        }
    }

    func testEndToEndBlobsOpenOnlyWhenTheyAreAPicture() throws {
        for e in try vectors().e2e {
            let link = try XCTUnwrap(HtreeLink(XCTUnwrap(URL(string: e.link))), e.name)
            XCTAssertEqual(link.blobHash, e.blobHash, e.name)
            XCTAssertEqual(link.sha256, e.plainSha256, e.name)
            let photo = link.open(unhex(e.blob))
            if e.show {
                XCTAssertEqual(photo.map { hex($0.data) }, e.plain, e.name)
                XCTAssertEqual(photo?.mime, e.mime, e.name)
            } else {
                XCTAssertNil(photo, e.name)
            }
        }
    }

    func testOtherBytesOrAnotherKeyAreNeverOpened() throws {
        let e = try vectors().e2e[0]
        let link = try XCTUnwrap(HtreeLink(XCTUnwrap(URL(string: e.link))))
        var tampered = unhex(e.blob)
        tampered[0] ^= 1
        XCTAssertNil(link.open(tampered))
        var wrong = link
        wrong.chk = Data(repeating: 9, count: 32)
        XCTAssertNil(wrong.open(unhex(e.blob)))
        XCTAssertNil(link.open(Data(count: HtreeLink.maxBlobBytes + 1)))
    }

    func testServersIrisFirstThenTheAuthorsThenOurs() throws {
        let link = try XCTUnwrap(HtreeLink(XCTUnwrap(URL(string: try vectors().e2e[0].link))))
        let urls = link.candidates(authorServers: ["a.example/", "http://b.example"], ownServers: ["https://upload.iris.to", "c.example"])
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://upload.iris.to/\(link.blobHash)", "https://a.example/\(link.blobHash)", "https://c.example/\(link.blobHash)",
        ])
    }

    func testANameThatSaysVideoStaysText() throws {
        let e = try vectors().e2e[0]
        let url = try XCTUnwrap(URL(string: e.link.replacingOccurrences(of: "dot.jpg", with: "clip.mp4")))
        XCTAssertNotNil(HtreeLink(url))
        XCTAssertFalse(SupportedMediaFormats.isMediaURL(url))
    }

    func testSniffKnowsPicturesOnly() {
        XCTAssertEqual(HtreeLink.sniffImage(Data([0xff, 0xd8, 0xff, 0xe0])), "image/jpeg")
        XCTAssertEqual(HtreeLink.sniffImage(Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0])), "image/png")
        XCTAssertEqual(HtreeLink.sniffImage(Data("GIF89a..".utf8)), "image/gif")
        XCTAssertEqual(HtreeLink.sniffImage(Data("RIFF....WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(HtreeLink.sniffImage(Data("<svg>".utf8)))
        XCTAssertNil(HtreeLink.sniffImage(Data([0x82, 0xa1, 0x6c, 0x90, 0xa1, 0x74, 0x02])), "a tree node is not a picture")
    }

    func testTheRealPhoto() throws {
        guard let path = ProcessInfo.processInfo.environment["HTREE_REAL_BLOB"] else { return }
        let v = try vectors()
        let link = try XCTUnwrap(HtreeLink(XCTUnwrap(URL(string: v.note.link))))
        let photo = try XCTUnwrap(link.open(Data(contentsOf: URL(fileURLWithPath: path))))
        XCTAssertEqual(photo.data.count, v.note.plainBytes)
        XCTAssertEqual(photo.mime, "image/jpeg")
    }
}
