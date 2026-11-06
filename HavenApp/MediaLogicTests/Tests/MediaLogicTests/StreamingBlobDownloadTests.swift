import XCTest
import CryptoKit
@testable import MediaLogic

/// Logen 2026-11-06 (Tory's media limits): Import media read each whole file
/// into memory, so a 600 MB video could kill the app on a phone. The download
/// now goes to a temp file in chunks, hashed as it arrives.
final class StreamingBlobDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sbd-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ChunkedStub.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ChunkedStub.self]
        return c
    }

    private func leftovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private let plenty: @Sendable () -> Int64? = { 1 << 40 }

    func testA64MBFileStreamsToDiskInChunksAndItsHashIsChecked() async throws {
        ChunkedStub.configure(chunks: 64, chunkSize: 1 << 20)
        let request = URLRequest(url: URL(string: "https://media.example/video.mp4")!)
        var download: StreamingBlobDownload?
        let result = await StreamingBlobDownload.fetch(request, configuration: config(), directory: dir,
                                                       expectedSHA256: ChunkedStub.sha256, freeBytes: plenty,
                                                       observe: { download = $0 })
        let file = try result.get()
        XCTAssertEqual(file.size, 64 << 20)
        XCTAssertEqual(file.sha256, ChunkedStub.sha256)
        XCTAssertEqual(file.contentType, "video/mp4")
        let onDisk = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int
        XCTAssertEqual(onDisk, 64 << 20)
        // Never the whole file at once: the most held in memory is one chunk.
        let peak = try XCTUnwrap(download).peakChunkBytes
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, 4 << 20, "held \(peak) bytes at once")
        try FileManager.default.removeItem(at: file.url)
    }

    func testAWrongHashLeavesNoFileBehind() async {
        ChunkedStub.configure(chunks: 3, chunkSize: 1 << 20)
        let request = URLRequest(url: URL(string: "https://media.example/x")!)
        let wrong = String(repeating: "0", count: 64)
        let result = await StreamingBlobDownload.fetch(request, configuration: config(), directory: dir,
                                                       expectedSHA256: wrong, freeBytes: plenty)
        guard case .failure(.hashMismatch(let expected, let got)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(expected, wrong)
        XCTAssertEqual(got, ChunkedStub.sha256)
        XCTAssertEqual(leftovers(), [])
    }

    func testNoRoomIsRefusedAtTheHeadersBeforeTheBody() async {
        ChunkedStub.configure(chunks: 64, chunkSize: 1 << 20)
        let request = URLRequest(url: URL(string: "https://media.example/big")!)
        let result = await StreamingBlobDownload.fetch(request, configuration: config(), directory: dir,
                                                       freeBytes: { 100 << 20 })
        guard case .failure(.noRoom(let room)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(room, .noRoom(need: 2 * (64 << 20) + BlobImportRoom.margin, free: 100 << 20))
        XCTAssertNotNil(room.reason)
        XCTAssertEqual(leftovers(), [])
        XCTAssertLessThan(ChunkedStub.sentChunks, 32, "the body should not be read")
    }

    func testAnErrorStatusStoresNothing() async {
        ChunkedStub.configure(chunks: 1, chunkSize: 10, status: 404)
        let request = URLRequest(url: URL(string: "https://media.example/gone")!)
        let result = await StreamingBlobDownload.fetch(request, configuration: config(), directory: dir, freeBytes: plenty)
        XCTAssertEqual(result, .failure(.status(404)))
        XCTAssertEqual(leftovers(), [])
    }

    func testRoomRule() {
        let margin = BlobImportRoom.margin
        XCTAssertEqual(BlobImportRoom.decide(declared: 600 << 20, free: 1200 << 20 + margin), .fits)
        XCTAssertEqual(BlobImportRoom.decide(declared: 600 << 20, free: 1200 << 20 + margin - 1),
                       .noRoom(need: 1200 << 20 + margin, free: 1200 << 20 + margin - 1))
        // Unknown size: only the margin, checked again once the file is down.
        XCTAssertEqual(BlobImportRoom.decide(declared: nil, free: margin), .fits)
        XCTAssertEqual(BlobImportRoom.decideAfterDownload(size: 600 << 20, free: 600 << 20 + margin), .fits)
        XCTAssertNotEqual(BlobImportRoom.decideAfterDownload(size: 600 << 20, free: 600 << 20), .fits)
        XCTAssertNotEqual(BlobImportRoom.decide(declared: .max, free: .max - 1), .fits)
    }

    func testBigFilesFromTheOwnerSkipTheBufferedUpload() {
        let big = OwnVaultUpload.inProcessAbove + 1
        XCTAssertEqual(OwnVaultUpload.route(keyless: false, bytes: big, activeIsOwner: true), .inProcess)
        XCTAssertEqual(OwnVaultUpload.route(keyless: false, bytes: OwnVaultUpload.inProcessAbove, activeIsOwner: true), .signedUpload)
        // Another account's file stays its own signed upload.
        XCTAssertEqual(OwnVaultUpload.route(keyless: false, bytes: big, activeIsOwner: false), .signedUpload)
        XCTAssertEqual(OwnVaultUpload.route(keyless: true, bytes: 1, activeIsOwner: false), .inProcess)
    }
}

/// Serves a body of `chunks` × `chunkSize` deterministic bytes, one chunk per
/// callback, with a Content-Length.
final class ChunkedStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chunks = 0
    nonisolated(unsafe) private static var chunkSize = 0
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var sent = 0
    nonisolated(unsafe) private(set) static var sha256 = ""
    private var stopped = false

    static var sentChunks: Int { lock.withLock { sent } }

    static func reset() { lock.withLock { sent = 0 } }

    static func configure(chunks: Int, chunkSize: Int, status: Int = 200) {
        lock.withLock {
            self.chunks = chunks
            self.chunkSize = chunkSize
            self.status = status
            self.sent = 0
        }
        var hasher = SHA256()
        for i in 0..<chunks { hasher.update(data: chunk(i, size: chunkSize)) }
        sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func chunk(_ i: Int, size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ i) })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (n, size, code) = Self.lock.withLock { (Self.chunks, Self.chunkSize, Self.status) }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(n * size)", "Content-Type": "video/mp4"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async {
            for i in 0..<n {
                if Self.lock.withLock({ self.stopped }) { return }
                self.client?.urlProtocol(self, didLoad: Self.chunk(i, size: size))
                Self.lock.withLock { Self.sent += 1 }
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        Self.lock.withLock { stopped = true }
    }
}
