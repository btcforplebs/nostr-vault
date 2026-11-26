import XCTest
@testable import MediaLogic

/// Settings › Media Servers › Upload Quality (plan A4, Android twin #2561):
/// Standard by default, Original sends notes, share, live chat and DM photos
/// and videos as they are, and the Media tab always keeps the original.
final class UploadQualityTests: XCTestCase {
    private static let app = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.app.appendingPathComponent("HavenApp/\(path)"), encoding: .utf8)
    }

    // MARK: The setting

    func testSettingMapsToQuality() {
        XCTAssertEqual(UploadQuality.from("standard"), .standard)
        XCTAssertEqual(UploadQuality.from("original"), .original)
        XCTAssertEqual(UploadQuality.from(""), .standard, "anything unknown is Standard")
        XCTAssertEqual(UploadQuality.from("Original"), .standard)
        XCTAssertEqual(UploadQuality.normalized("bogus"), "standard")
        XCTAssertEqual(UploadQuality.normalized("original"), "original")
        XCTAssertEqual(UploadQuality.label("original"), "Original")
        XCTAssertEqual(UploadQuality.label("standard"), "Standard")
    }

    func testDefaultIsStandard() throws {
        XCTAssertEqual(HavenConfig.default.uploadQuality, "standard")
        // A config.json from before the setting loads as Standard.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HavenConfig.default)) as? [String: Any])
        json.removeValue(forKey: "uploadQuality")
        let old = try JSONDecoder().decode(HavenConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.uploadQuality, "standard")
    }

    /// Picked once, it is still Original after the app quits and starts
    /// again: written to config.json and read back by the same store.
    func testOriginalSurvivesRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("upload-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigFileStore(url: dir.appendingPathComponent("config.json"))

        var config = HavenConfig.default
        config.uploadQuality = UploadQuality.original
        try store.write(JSONEncoder().encode(config))

        guard case .loaded(let loaded, false) = ConfigFileStore(url: dir.appendingPathComponent("config.json"))
            .load(HavenConfig.self, hasKey: { _ in false }) else {
            return XCTFail("config.json did not load")
        }
        XCTAssertEqual(loaded.uploadQuality, "original")
        XCTAssertEqual(UploadQuality.from(loaded.uploadQuality), .original)
    }

    // MARK: Who reads it

    /// Every note, share, live chat and DM upload takes its quality from the
    /// setting; none is fixed at Standard any more.
    func testUploadsReadTheSetting() throws {
        let readers: [(String, Int)] = [
            ("Views/Compose/ComposeView+Attachments.swift", 2),   // picked + dropped photos
            ("Views/Compose/ComposeView+Uploads.swift", 1),       // note videos
            ("Views/Live/LiveChatAttachMenu.swift", 1),           // live chat photos
            ("Services/SharePortal/Handlers/MediaPostShareHandler.swift", 1), // share photos + videos
            ("Views/MediaGallery/MediaGalleryView.swift", 2),     // shared into the Vault (iOS + Mac)
            ("Views/DMThreadView.swift", 1),                      // DM photos
        ]
        for (path, uses) in readers {
            let src = try source(path)
            XCTAssertEqual(src.components(separatedBy: "UploadQuality.current").count - 1, uses, path)
            XCTAssertFalse(src.contains("quality: .standard"), "\(path) still fixes Standard")
        }
    }

    /// The Media tab is your backup: its own picks stay Original.
    func testMediaTabKeepsOriginal() throws {
        let src = try source("Views/MediaGallery/MediaGalleryUpload.swift")
        XCTAssertTrue(src.contains("ImageCompressor.prepare(data, type: contentType, quality: .original)"))
        XCTAssertTrue(src.contains("quality: ImageCompressor.Quality = .original"))
        XCTAssertFalse(src.contains("UploadQuality.current"))
    }

    /// Original only skips the shrinking: the location still comes out.
    func testOriginalDMPhotoStillRemovesLocation() throws {
        let src = try source("Views/DM/DMPhotoQuality.swift")
        XCTAssertTrue(src.contains("MediaPrivacy.removingLocation(fromImageData:"))
    }
}
