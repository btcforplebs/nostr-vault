import CryptoKit
import Foundation
import XCTest
@testable import MediaLogic

/// A media backup restore moves a file in only when its bytes hash to the
/// name, swaps an existing blob atomically, and finds blobs inside folders.
final class BlossomArchiveRestoreTests: XCTestCase {
    private var staging: URL!
    private var blossom: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-restore-\(UUID().uuidString)")
        staging = root.appendingPathComponent("staging")
        blossom = root.appendingPathComponent("blossom")
        for dir in [staging!, blossom!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func put(_ data: Data, as name: String, in dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name))
    }

    func testAWrongBytesEntryNeverReplacesAGoodPhoto() throws {
        let photo = Data("the real photo".utf8)
        let sha = hash(photo)
        try put(photo, as: sha, in: blossom)
        try put(Data("something else".utf8), as: "\(sha).jpg", in: staging)

        let result = BlossomArchiveRestore.restore(from: staging, into: blossom)
        XCTAssertEqual(result, .init(imported: 0, mismatched: 1, skipped: 0))
        XCTAssertEqual(try Data(contentsOf: blossom.appendingPathComponent(sha)), photo)
    }

    func testAMatchingEntryReplacesAndFoldersAreRead() throws {
        let photo = Data("photo".utf8), video = Data("video".utf8)
        try put(Data("stale".utf8), as: hash(photo), in: blossom)
        try put(photo, as: "\(hash(photo)).jpg", in: staging)
        try put(video, as: "\(hash(video)).mp4", in: staging.appendingPathComponent("media"))
        try put(Data("x".utf8), as: "notes.txt", in: staging)
        try put(Data("x".utf8), as: "._\(hash(photo)).jpg", in: staging.appendingPathComponent("__MACOSX"))

        let result = BlossomArchiveRestore.restore(from: staging, into: blossom)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(try Data(contentsOf: blossom.appendingPathComponent(hash(photo))), photo)
        XCTAssertEqual(try Data(contentsOf: blossom.appendingPathComponent(hash(video))), video)
    }

    func testAnEmptyArchiveImportsNothing() {
        XCTAssertEqual(BlossomArchiveRestore.restore(from: staging, into: blossom).imported, 0)
    }
}
