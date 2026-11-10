import XCTest
@testable import MediaLogic

/// The in-memory hash (used when the bytes are kept for the caller) and the
/// streaming hash (used to check a file without keeping it) must agree, or a
/// healthy local blob would be quarantined as corrupt by one path only.
final class HashNamedFileCheckTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hash-named-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testKnownDigest() {
        XCTAssertEqual(HashNamedFileCheck.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStreamingMatchesInMemoryAcrossChunkBoundary() throws {
        // Just over two 1 MB chunks, so the streaming loop runs three times.
        var bytes = Data(count: (2 << 20) + 17)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        let file = dir.appendingPathComponent("blob")
        try bytes.write(to: file)
        XCTAssertEqual(HashNamedFileCheck.sha256Hex(streaming: file), HashNamedFileCheck.sha256Hex(bytes))
    }

    func testStreamingEmptyFile() throws {
        let file = dir.appendingPathComponent("empty")
        try Data().write(to: file)
        XCTAssertEqual(HashNamedFileCheck.sha256Hex(streaming: file),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testStreamingMissingFileIsNil() {
        XCTAssertNil(HashNamedFileCheck.sha256Hex(streaming: dir.appendingPathComponent("absent")))
    }
}
