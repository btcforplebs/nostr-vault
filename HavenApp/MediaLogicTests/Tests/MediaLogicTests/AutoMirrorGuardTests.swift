import XCTest
@testable import MediaLogic

/// The Mac's Auto-Mirror makes the box's checks (haven-go/auto_mirror.go
/// fetchIntoVault; parity report §4, 2026-11-22).
final class AutoMirrorGuardTests: XCTestCase {
    private let h1 = String(repeating: "a", count: 64)
    private let h2 = String(repeating: "b", count: 64)

    func testCapIsTheBoxBlobCap() {
        XCTAssertEqual(AutoMirrorGuard.maxFileBytes, 256 * 1024 * 1024)
    }

    func testActiveTypesAreRefusedAndMediaIsKept() {
        for type in ["text/html", "image/svg+xml", "application/javascript", "text/javascript",
                     "application/xhtml+xml", "text/xml", "application/xml", "TEXT/HTML; charset=utf-8"] {
            XCTAssertFalse(AutoMirrorGuard.allowsType(declared: type, url: nil), type)
        }
        for type in ["image/jpeg", "video/mp4", "audio/mpeg", "application/octet-stream", "image/png; charset=binary"] {
            XCTAssertTrue(AutoMirrorGuard.allowsType(declared: type, url: nil), type)
        }
        // Not a type/subtype at all.
        XCTAssertFalse(AutoMirrorGuard.allowsType(declared: "garbage", url: nil))
    }

    func testNoDeclaredTypeUsesTheExtension() {
        XCTAssertFalse(AutoMirrorGuard.allowsType(declared: nil, url: URL(string: "https://x.example/a.svg")))
        XCTAssertFalse(AutoMirrorGuard.allowsType(declared: "", url: URL(string: "https://x.example/a.html")))
        XCTAssertTrue(AutoMirrorGuard.allowsType(declared: nil, url: URL(string: "https://x.example/a.jpg")))
        // Nothing says: allowed, stored as octet-stream (as on the box).
        XCTAssertTrue(AutoMirrorGuard.allowsType(declared: nil, url: URL(string: "https://x.example/a")))
    }

    func testExpectedHashIsTheLinkNameThenTheImeta() {
        let named = URL(string: "https://cdn.example/\(h1).jpg")!
        XCTAssertEqual(AutoMirrorGuard.expectedHash(for: named, imeta: [named.absoluteString: h2]), h1)
        let plain = URL(string: "https://cdn.example/photo.jpg")!
        XCTAssertEqual(AutoMirrorGuard.expectedHash(for: plain, imeta: [plain.absoluteString: h2]), h2)
        XCTAssertNil(AutoMirrorGuard.expectedHash(for: plain, imeta: [:]))
    }

    /// The note-link half passes the expected hash (it used to pass none).
    func testNoteLinkFetchPassesTheExpectedHash() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HavenApp/Services/Blossom/BlossomService+ExternalMirror.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("AutoMirrorGuard.expectedHash(for: $0, imeta: knownHashes)"))
        XCTAssertTrue(src.contains("self.fetchFromURL(url, expectedSHA256: want[url.absoluteString] ?? nil, autoMirror: true)"))
        XCTAssertTrue(src.contains("self.fetchFromMirrors(sha256: hash, autoMirror: true)"))
    }
}
