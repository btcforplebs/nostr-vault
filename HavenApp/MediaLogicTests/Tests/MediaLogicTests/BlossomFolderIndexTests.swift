import XCTest
@testable import MediaLogic

/// The vault's Blossom folder, looked up by hash without listing it per photo.
final class BlossomFolderIndexTests: XCTestCase {
    private var dir: URL!
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("folder-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    func testMissesDoNotListTheFolderAgainWhileNothingChanged() throws {
        try write("\(a).jpg")
        let index = BlossomFolderIndex()
        XCTAssertEqual(index.file(forHash: a, in: dir)?.lastPathComponent, "\(a).jpg")
        for _ in 0..<50 { XCTAssertNil(index.file(forHash: b, in: dir)) }
        XCTAssertEqual(index.listings, 1)
    }

    func testAFileTheRelayAddsIsFoundOnTheNextLookup() throws {
        let index = BlossomFolderIndex()
        XCTAssertNil(index.file(forHash: b, in: dir))
        try write("\(b).mp4")
        XCTAssertEqual(index.file(forHash: b, in: dir)?.lastPathComponent, "\(b).mp4")
    }

    func testAFileRenamedIntoPlaceIsFound() throws {
        let index = BlossomFolderIndex()
        try write("staging.tmp")
        XCTAssertNil(index.file(forHash: a, in: dir))
        try FileManager.default.moveItem(at: dir.appendingPathComponent("staging.tmp"),
                                         to: dir.appendingPathComponent("\(a).png"))
        XCTAssertEqual(index.file(forHash: a, in: dir)?.lastPathComponent, "\(a).png")
    }

    func testADeletedFileIsGoneOnTheNextLookup() throws {
        try write("\(a).jpg")
        let index = BlossomFolderIndex()
        XCTAssertNotNil(index.file(forHash: a, in: dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(a).jpg"))
        XCTAssertNil(index.file(forHash: a, in: dir))
    }

    func testACorruptCopyIsNeverReturned() throws {
        try write("\(a).jpg.corrupt")
        let index = BlossomFolderIndex()
        XCTAssertNil(index.file(forHash: a, in: dir))
    }

    func testAnotherFolderIsListedOnItsOwn() throws {
        try write("\(a).jpg")
        let index = BlossomFolderIndex()
        XCTAssertNotNil(index.file(forHash: a, in: dir))
        let other = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(index.file(forHash: a, in: other))
    }

    func testInvalidateListsAgain() throws {
        let index = BlossomFolderIndex()
        _ = index.file(forHash: a, in: dir)
        index.invalidate()
        _ = index.file(forHash: a, in: dir)
        XCTAssertEqual(index.listings, 2)
    }
}
