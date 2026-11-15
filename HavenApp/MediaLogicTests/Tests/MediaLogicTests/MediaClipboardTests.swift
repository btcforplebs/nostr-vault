import XCTest
@testable import MediaLogic

/// Copy puts the media itself on the clipboard, in its own format.
final class MediaClipboardTests: XCTestCase {
    private func bytes(_ b: [UInt8]) -> Data { Data(b) }

    func testFormatFromFirstBytes() {
        XCTAssertEqual(MediaClipboard.format(of: Data("GIF89a....".utf8)), .gif)
        XCTAssertEqual(MediaClipboard.format(of: Data("GIF87a....".utf8)), .gif)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .png)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])), .jpeg)
        XCTAssertEqual(MediaClipboard.format(of: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)), .webp)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0, 0, 0, 0x18]) + Data("ftypheic".utf8)), .heic)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0, 0, 0, 0x18]) + Data("ftypisom".utf8)), .mp4)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0, 0, 0, 0x18]) + Data("ftypmp42".utf8)), .mp4)
        XCTAssertEqual(MediaClipboard.format(of: bytes([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8)), .mov)
        XCTAssertEqual(MediaClipboard.format(of: Data("hello".utf8)), .other)
        XCTAssertEqual(MediaClipboard.format(of: Data()), .other)
    }

    /// A GIF goes on as a GIF, or it pastes as one still frame.
    func testPasteboardTypes() {
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .gif), "com.compuserve.gif")
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .png), "public.png")
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .jpeg), "public.jpeg")
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .heic), "public.heic")
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .mp4), "public.mpeg-4")
        XCTAssertEqual(MediaClipboard.pasteboardType(for: .mov), "com.apple.quicktime-movie")
        XCTAssertNil(MediaClipboard.pasteboardType(for: .webp), "re-drawn as PNG")
        XCTAssertNil(MediaClipboard.pasteboardType(for: .other))
    }

    func testFileExtensions() {
        XCTAssertEqual(MediaClipboard.fileExtension(for: .gif, isClip: false), "gif")
        XCTAssertEqual(MediaClipboard.fileExtension(for: .jpeg, isClip: false), "jpg")
        XCTAssertEqual(MediaClipboard.fileExtension(for: .mov, isClip: true), "mov")
        XCTAssertEqual(MediaClipboard.fileExtension(for: .other, isClip: true), "mp4")
        XCTAssertEqual(MediaClipboard.fileExtension(for: .other, isClip: false), "png")
        XCTAssertEqual(MediaClipboard.fileExtension(for: .webp, isClip: false), "png")
    }
}
