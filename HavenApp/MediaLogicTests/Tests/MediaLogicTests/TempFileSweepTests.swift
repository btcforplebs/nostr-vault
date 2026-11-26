import XCTest
@testable import MediaLogic

/// The file times can't be set back (status-change time is the kernel's), so
/// "old" here is the sweep run two days ahead of the files.
final class TempFileSweepTests: XCTestCase {
    var root: URL!
    var tmp: URL!
    let fm = FileManager.default
    let twoDays: TimeInterval = 48 * 60 * 60

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("TempFileSweepTests-\(UUID().uuidString)")
        tmp = root.appendingPathComponent("tmp")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    private func write(_ name: String, in dir: URL? = nil, bytes: Int = 10) throws -> URL {
        let u = (dir ?? tmp).appendingPathComponent(name)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: u)
        return u
    }
    private func exists(_ u: URL) -> Bool { (try? u.checkResourceIsReachable()) == true || fm.fileExists(atPath: u.path) }

    func testFreshPartWithLiveJobKeptAndTwoDayOldOrphanRemoved() throws {
        let live = try write("import-\(UUID().uuidString).part", bytes: 100)
        let orphan = try write("import-\(UUID().uuidString).part", bytes: 2_000)
        let leases = TempFileLeases()
        leases.hold(live)

        // Today: nothing is old yet, both stay.
        var r = TempFileSweep.sweep(directory: tmp, isHeld: leases.isHeld)
        XCTAssertEqual(r.removed, 0)
        XCTAssertTrue(exists(live)); XCTAssertTrue(exists(orphan))

        // Two days on: the orphan goes, the held one stays however old.
        r = TempFileSweep.sweep(directory: tmp, now: Date().addingTimeInterval(twoDays), isHeld: leases.isHeld)
        XCTAssertTrue(exists(live), "a .part its job still holds was removed")
        XCTAssertFalse(exists(orphan))
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.removedBytes, 2_000)

        // Released: now it may go too.
        leases.release(live)
        r = TempFileSweep.sweep(directory: tmp, now: Date().addingTimeInterval(twoDays), isHeld: leases.isHeld)
        XCTAssertFalse(exists(live))
    }

    func testFreshUnheldFileKept() throws {
        let f = try write("CFNetworkDownload_abc.tmp")
        let r = TempFileSweep.sweep(directory: tmp, isHeld: { _ in false })
        XCTAssertTrue(exists(f))
        XCTAssertEqual(r.kept, 1)
    }

    /// copyItem keeps the source's modified time; the status-change time is
    /// still new, so a photo picked from an old album is not swept mid-upload.
    func testOldModifiedTimeButJustCopiedKept() throws {
        let f = try write("haven-upload-\(UUID().uuidString)")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * twoDays)], ofItemAtPath: f.path)
        TempFileSweep.sweep(directory: tmp, isHeld: { _ in false })
        XCTAssertTrue(exists(f))
    }

    func testEveryKnownLeftoverKindGoesWhenOld() throws {
        let names = ["import-x.part", "import-ab-cd.blob", "CFNetworkDownload_Q1.tmp", "haven-upload-1",
                     "queued-\(String(repeating: "a", count: 64))", "homevault-abc-123456",
                     "blossom-backup-1762.zip", "haven-backup-1762.zip", "nostrvault-backup-1.zip",
                     "nv-video-1.mp4", "dm-video-1.mp4", "\(UUID().uuidString).mp4"]
        for n in names { try write(n) }
        try write("a.jpg", in: tmp.appendingPathComponent("BlossomExport_1"), bytes: 500)
        let r = TempFileSweep.sweep(directory: tmp, now: Date().addingTimeInterval(twoDays), isHeld: { _ in false })
        XCTAssertEqual(r.removed, names.count + 1)
        XCTAssertEqual(r.removedBytes, Int64(names.count * 10 + 500))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path), [])
    }

    func testForeignNamesSymlinksAndOutsideNeverTouched() throws {
        let sock = try write("nvr.sock")
        let havenFallback = try write("drafts.json", in: tmp.appendingPathComponent("Haven"))
        let other = try write("com.apple.something.plist")
        let blobDir = root.appendingPathComponent("haven_database/blossom")
        let blob = try write(String(repeating: "c", count: 64), in: blobDir)
        let oldOutside = try write("import-outside.part", in: root)
        let link = tmp.appendingPathComponent("import-link.part")
        try fm.createSymbolicLink(at: link, withDestinationURL: blob)

        TempFileSweep.sweep(directory: tmp, now: Date().addingTimeInterval(twoDays), isHeld: { _ in false })
        for u in [sock, havenFallback, other, blob, oldOutside] { XCTAssertTrue(exists(u), u.lastPathComponent) }
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "symlink removed")
    }

    /// `<sha>.mp4` is a hard link to the blob: kept while the blob is there
    /// (removing it would free nothing), removed once the blob is gone.
    func testPlayableHardLinkOnlyGoesWhenBlobIsGone() throws {
        let sha = String(repeating: "ab", count: 32)
        let blobDir = root.appendingPathComponent("haven_database/blossom")
        let blob = try write(sha, in: blobDir, bytes: 300)
        let link = tmp.appendingPathComponent(sha + ".mp4")
        try fm.linkItem(at: blob, to: link)
        let later = Date().addingTimeInterval(twoDays)

        var r = TempFileSweep.sweep(directory: tmp, now: later, isHeld: { _ in false })
        XCTAssertTrue(exists(link)); XCTAssertTrue(exists(blob))
        XCTAssertEqual(r.removed, 0)

        try fm.removeItem(at: blob)
        r = TempFileSweep.sweep(directory: tmp, now: later, isHeld: { _ in false })
        XCTAssertFalse(exists(link))
        XCTAssertEqual(r.removedBytes, 300)
    }

    func testHeldFileInsideFolderKeepsFolder() throws {
        let inner = try write("a.zip", in: tmp.appendingPathComponent("BlossomImport_1"))
        let leases = TempFileLeases()
        leases.hold(inner)
        TempFileSweep.sweep(directory: tmp, now: Date().addingTimeInterval(twoDays), isHeld: leases.isHeld)
        XCTAssertTrue(exists(inner))
    }
}
