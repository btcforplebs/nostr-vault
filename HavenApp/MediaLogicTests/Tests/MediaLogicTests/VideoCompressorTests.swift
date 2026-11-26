import AVFoundation
import CoreVideo
import XCTest
@testable import MediaLogic

final class VideoCompressorTests: XCTestCase {
    // MARK: - Rules (the same cases as Android's VideoCompressorTest)

    private func source(_ w: Int, _ h: Int, bps: Int, h264: Bool = true) -> VideoCompressor.Source {
        VideoCompressor.Source(width: w, height: h, bitrate: bps, isH264: h264)
    }

    func testFourKShrinksTo720LongEdgeAt5Mbps() {
        XCTAssertEqual(VideoCompressor.plan(source(3840, 2160, bps: 45_000_000, h264: false), quality: .standard),
                       .encode(width: 720, height: 404, bitrate: 5_000_000))
        XCTAssertEqual(VideoCompressor.plan(source(2160, 3840, bps: 45_000_000), quality: .standard),
                       .encode(width: 404, height: 720, bitrate: 5_000_000))
    }

    func testOriginalKeepsEveryByte() {
        XCTAssertEqual(VideoCompressor.plan(source(3840, 2160, bps: 45_000_000), quality: .original), .keep)
    }

    func testSmallH264ClipKeepsItsBytes() {
        XCTAssertEqual(VideoCompressor.plan(source(720, 404, bps: 6_000_000), quality: .standard), .keep)
        XCTAssertEqual(VideoCompressor.plan(source(640, 480, bps: 1_000_000), quality: .standard), .keep)
    }

    func testSmallHEVCOrFastClipIsReencodedAtItsOwnSize() {
        XCTAssertEqual(VideoCompressor.plan(source(720, 404, bps: 3_000_000, h264: false), quality: .standard),
                       .encode(width: 720, height: 404, bitrate: 3_000_000))
        XCTAssertEqual(VideoCompressor.plan(source(720, 404, bps: 9_000_000), quality: .standard),
                       .encode(width: 720, height: 404, bitrate: 5_000_000))
    }

    func testBitrateNeverAboveTheClipsOwn() {
        XCTAssertEqual(VideoCompressor.plan(source(1920, 1080, bps: 2_000_000), quality: .standard),
                       .encode(width: 720, height: 404, bitrate: 2_000_000))
    }

    func testUnknownSizeIsLeftAlone() {
        XCTAssertEqual(VideoCompressor.plan(source(0, 0, bps: 9_000_000), quality: .standard), .keep)
    }

    // MARK: - Real encode

    /// A 1080p H.264 clip at a high bitrate, written frame by frame; `rotated` tags it portrait.
    private func makeClip(rotated: Bool = false, seconds: Int = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt64.self)
            let count = CVPixelBufferGetBytesPerRow(pixels) * 1080 / 8
            // Noise: hard to compress, so the source is big.
            var seed = UInt64(frame + 1) &* 0x9E3779B97F4A7C15
            for i in 0..<count {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                base[i] = seed
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }

    func testCompressesToSmaller720pMP4() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }
        let seen = Locked<[Double]>([])
        guard let out = await VideoCompressor.compressed(fileAt: clip, quality: .standard, progress: { p in
            seen.update { $0.append(p) }
        }) else { return XCTFail("not compressed") }
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertLessThan(size(out), size(clip))
        XCTAssertEqual(out.pathExtension, "mp4")
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first!
        let (natural, formats) = try await track.load(.naturalSize, .formatDescriptions)
        XCTAssertEqual(natural, CGSize(width: 720, height: 404))
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kCMVideoCodecType_H264)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        XCTAssertEqual(seen.value.last, 1)
        XCTAssertTrue(seen.value.contains { $0 > 0 && $0 < 1 })
    }

    func testPortraitClipComesOutUpright() async throws {
        let clip = try makeClip(rotated: true, seconds: 1)
        defer { try? FileManager.default.removeItem(at: clip) }
        guard let out = await VideoCompressor.compressed(fileAt: clip, quality: .standard)
        else { return XCTFail("not compressed") }
        defer { try? FileManager.default.removeItem(at: out) }
        let track = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first!
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        XCTAssertEqual(natural.applying(transform).width.magnitude, 404)
        XCTAssertEqual(natural.applying(transform).height.magnitude, 720)
    }

    func testOriginalAndUnreadableGoUpAsTheyAre() async throws {
        let clip = try makeClip(seconds: 1)
        defer { try? FileManager.default.removeItem(at: clip) }
        let original = await VideoCompressor.compressed(fileAt: clip, quality: .original)
        XCTAssertNil(original)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("vc-junk-\(UUID().uuidString).mov")
        try Data(repeating: 7, count: 4096).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let unreadable = await VideoCompressor.compressed(fileAt: junk, quality: .standard)
        XCTAssertNil(unreadable)
    }
}

/// A value the progress callback writes from the compressor's queue.
private final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
