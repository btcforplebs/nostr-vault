import XCTest
@testable import MediaLogic

final class MediaTypeFilterTests: XCTestCase {
    func testAudioByMimeType() {
        for mime in ["audio/mpeg", "audio/mp4", "AUDIO/ogg", "audio/x-wav"] {
            XCTAssertEqual(MediaTypeFilter.category(mimeType: mime, pathExtension: "", fallback: .other), .audio, mime)
        }
    }

    func testAudioByExtension() {
        for ext in ["mp3", "m4a", "aac", "wav", "ogg", "opus", "FLAC"] {
            XCTAssertEqual(MediaTypeFilter.category(mimeType: nil, pathExtension: ext, fallback: .other), .audio, ext)
        }
    }

    func testNonAudioKeepsItsChip() {
        XCTAssertEqual(MediaTypeFilter.category(mimeType: "image/jpeg", pathExtension: "jpg", fallback: .photo), .photo)
        XCTAssertEqual(MediaTypeFilter.category(mimeType: "video/mp4", pathExtension: "mp4", fallback: .video), .video)
        XCTAssertEqual(MediaTypeFilter.category(mimeType: nil, pathExtension: "pdf", fallback: .other), .other)
        XCTAssertEqual(MediaTypeFilter.category(mimeType: "image/gif", pathExtension: "", fallback: .photo), .gif)
        XCTAssertEqual(MediaTypeFilter.category(mimeType: nil, pathExtension: "gif", fallback: .photo), .gif)
    }

    func testAudioChipSitsAfterGIF() {
        XCTAssertEqual(MediaTypeFilter.allCases.map(\.rawValue), ["Photo", "Video", "GIF", "Audio", "Other"])
    }

    func testOldAllSelectionStillShowsEverything() {
        XCTAssertEqual(MediaTypeFilter.selection(from: "Photo,Video,GIF,Other"), Set(MediaTypeFilter.allCases))
        XCTAssertEqual(MediaTypeFilter.selection(from: ""), Set(MediaTypeFilter.allCases))
        XCTAssertEqual(MediaTypeFilter.selection(from: "Photo,GIF"), [.photo, .gif])
        XCTAssertEqual(MediaTypeFilter.selection(from: "Audio"), [.audio])
    }

    func testRawSelectionRoundTrip() {
        let all = Set(MediaTypeFilter.allCases)
        XCTAssertEqual(MediaTypeFilter.selection(from: MediaTypeFilter.rawSelection(all)), all)
        XCTAssertEqual(MediaTypeFilter.rawSelection([.audio, .photo]), "Photo,Audio")
    }
}
