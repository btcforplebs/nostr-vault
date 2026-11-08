import XCTest
@testable import MediaLogic

/// A blob copied into the vault keeps the photo's own date on disk, so the
/// Media grid (which dates unmatched files by modified time) doesn't jump it
/// to Today. A photo in two notes gets one date whatever order they arrive in.
final class CopiedInDateTests: XCTestCase {
    private let blob = String(repeating: "ab", count: 32)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("copiedin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mtime(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func testACopiedFileGetsThePhotosDateNotNow() throws {
        let file = dir.appendingPathComponent(blob)
        try Data([1, 2, 3]).write(to: file)
        let real = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertTrue(CopiedInDate.stamp(sha256: blob, in: dir, date: real))
        XCTAssertEqual(try mtime(file).timeIntervalSince1970, real.timeIntervalSince1970, accuracy: 1)
    }

    func testAFileStoredWithAnExtensionIsFound() throws {
        let file = dir.appendingPathComponent(blob + ".jpg")
        try Data([1]).write(to: file)
        let real = Date(timeIntervalSince1970: 1_500_000_000)
        XCTAssertTrue(CopiedInDate.stamp(sha256: blob, in: dir, date: real))
        XCTAssertEqual(try mtime(file).timeIntervalSince1970, real.timeIntervalSince1970, accuracy: 1)
    }

    func testNoDateOrAFutureDateLeavesTheFileAlone() throws {
        let file = dir.appendingPathComponent(blob)
        try Data([1]).write(to: file)
        let before = try mtime(file)
        let now = Date()
        XCTAssertFalse(CopiedInDate.stamp(sha256: blob, in: dir, date: nil, now: now))
        XCTAssertFalse(CopiedInDate.stamp(sha256: blob, in: dir, date: now.addingTimeInterval(3600), now: now))
        XCTAssertEqual(try mtime(file), before)
    }

    func testAMissingFileIsNotStamped() {
        XCTAssertFalse(CopiedInDate.stamp(sha256: blob, in: dir, date: Date(timeIntervalSince1970: 1)))
    }

    func testTheEarliestServerUploadTimeIsTheBlobsDate() {
        let dates = CopiedInDate.uploadedByHash([
            (sha256: blob.uppercased(), uploaded: 1_700_000_000),  // a later copy on a second server
            (sha256: blob, uploaded: 1_600_000_000),
            (sha256: blob, uploaded: 1_650_000_000),  // and a third, listed after the first
            (sha256: "cd", uploaded: 0),      // no time known
            (sha256: nil, uploaded: 5),       // no blob
        ])
        XCTAssertEqual(dates[blob], Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertNil(dates["cd"])
        XCTAssertEqual(dates.count, 1)
    }

    func testAPhotoInTwoNotesGetsOneDateInEitherOrder() {
        let old = (key: blob, date: Date(timeIntervalSince1970: 1_600_000_000))
        let new = (key: blob, date: Date(timeIntervalSince1970: 1_700_000_000))
        let a = CopiedInDate.newestByKey([old, new], key: { $0.key }, date: { $0.date })
        let b = CopiedInDate.newestByKey([new, old], key: { $0.key }, date: { $0.date })
        XCTAssertEqual(a[blob], new.date)
        XCTAssertEqual(a, b)
    }
}
