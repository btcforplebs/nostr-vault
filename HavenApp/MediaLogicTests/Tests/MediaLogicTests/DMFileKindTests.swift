import XCTest
@testable import MediaLogic

/// B11: a received PDF or other file is named for what it is and its opened
/// copy carries an extension Quick Look can read.
final class DMFileKindTests: XCTestCase {
    func testLabels() {
        XCTAssertEqual(DMFileKind.label("application/pdf"), "PDF document")
        XCTAssertEqual(DMFileKind.label("APPLICATION/PDF"), "PDF document")
        XCTAssertEqual(DMFileKind.label("audio/mpeg"), "Audio file")
        XCTAssertEqual(DMFileKind.label("application/octet-stream"), "File")
    }

    func testOpenedCopyKeepsItsExtension() {
        XCTAssertEqual(DMFile.fileExtension("application/pdf"), "pdf")
        XCTAssertEqual(DMFile.fileExtension("text/plain"), "txt")
        XCTAssertEqual(DMFile.fileExtension("application/x-unknown"), "bin")
        XCTAssertEqual(DMFile.fileExtension("image/png"), "png", "photos unchanged")
        XCTAssertEqual(DMFile.fileExtension("video/mp4"), "mp4", "videos unchanged")
    }

    func testTileOpensTheFile() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tile = try String(contentsOf: app.appendingPathComponent("HavenApp/Views/DM/LockedDMPhotoTile.swift"), encoding: .utf8)
        XCTAssertFalse(tile.contains("File (\\(sealed.mime))"), "the dead tile is gone")
        XCTAssertTrue(tile.contains("DMFileChip(url: url, mime: sealed.mime)"))
    }
}
