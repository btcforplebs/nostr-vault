import AVFoundation
import CoreMedia
import Foundation

/// Shrinks a video before it is uploaded (RESEARCH/NV_UPLOAD_COMPRESSION_2026_11_26.md §4.1, plan A3;
/// Logen 2026-11-26: 720p, 5 Mbps, AAC). The twin of Android's `service/media/VideoCompressor.kt`
/// (#2559), with the same numbers:
///
/// - **Standard** (notes, Share Portal posts, videos shared into the Vault): H.264 + AAC in MP4, the
///   long edge at most `longEdge`, video at most `videoBitrate` and never above the clip's own, HDR
///   toned down to SDR, laid out for streaming, no metadata written.
/// - A clip already small (`plan`: H.264, long edge ≤ `longEdge`, ≤ `keepBitrate`) keeps its bytes.
/// - **Original** (the Media tab) keeps every byte.
/// - When the clip can't be re-encoded, or the result isn't smaller, the source goes up as before.
///
/// Callers still run `MediaPrivacy` on what this returns, so the location never goes up. DM videos and
/// diVine keep their own size through `PreparedClip.export`.
enum VideoCompressor {
    /// Feed and share videos: the long edge at most this (Android `LONG_EDGE`).
    static let longEdge = 720
    /// Video bitrate after compressing, at most.
    static let videoBitrate = 5_000_000
    /// A clip already H.264 and this small at or under this bitrate goes up as it is.
    static let keepBitrate = 6_000_000
    static let audioBitrate = 128_000

    /// What the clip is, as far as `plan` needs to know. Zero when unknown.
    struct Source: Equatable, Sendable {
        /// Displayed size (rotation applied; either way round works).
        let width: Int
        let height: Int
        /// Whole-file bitrate, bits per second.
        let bitrate: Int
        let isH264: Bool
    }

    enum Plan: Equatable, Sendable {
        /// Upload the bytes as they are.
        case keep
        /// Re-encode at `width` × `height` (displayed, even) and `bitrate`.
        case encode(width: Int, height: Int, bitrate: Int)
    }

    // MARK: - Rules

    /// What to do with `source` at `quality`. Free of AVFoundation work so it can be tested alone.
    static func plan(_ source: Source, quality: ImageCompressor.Quality) -> Plan {
        guard quality == .standard else { return .keep }
        let long = max(source.width, source.height)
        let short = min(source.width, source.height)
        guard short > 0 else { return .keep }
        if source.isH264, long <= longEdge, (1...keepBitrate).contains(source.bitrate) { return .keep }
        // Never more than the clip already has: a small clip must not grow.
        let bitrate = (1..<videoBitrate).contains(source.bitrate) ? source.bitrate : videoBitrate
        guard long > longEdge else {
            return .encode(width: even(source.width), height: even(source.height), bitrate: bitrate)
        }
        let scale = Double(longEdge) / Double(long)
        return .encode(width: even(Int((Double(source.width) * scale).rounded())),
                       height: even(Int((Double(source.height) * scale).rounded())),
                       bitrate: bitrate)
    }

    /// Encoders want even sizes.
    private static func even(_ value: Int) -> Int { max(2, value & ~1) }

    // MARK: - Compressing

    /// The video to upload in place of the file at `url`: a new temporary `.mp4` the caller deletes, or nil
    /// when the source should go up as it is (Original, already small, can't be re-encoded, or not smaller).
    /// Never throws; a cancelled task gets nil too. `progress` runs from 0 to 1 while it re-encodes.
    static func compressed(fileAt url: URL, quality: ImageCompressor.Quality,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> URL? {
        guard quality == .standard else { return nil }
        let asset = AVURLAsset(url: url)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first,
              let source = await describe(asset, video: video, fileAt: url),
              case let .encode(width, height, bitrate) = plan(source, quality: quality)
        else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nv-video-\(UUID().uuidString).mp4")
        let started = Date()
        do {
            try await transcode(asset, video: video, to: out, width: width, height: height,
                                bitrate: bitrate, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            if !(error is CancellationError) { print("[VideoCompressor] sending as it is: \(error.localizedDescription)") }
            return nil
        }
        let before = fileSize(url) ?? 0
        guard let after = fileSize(out), after > 0, after < before else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        print("[VideoCompressor] \(before) -> \(after) bytes (\(source.width)x\(source.height) \(source.bitrate) bps"
              + " -> \(width)x\(height) \(bitrate) bps) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        return out
    }

    private static func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Displayed size, whole-file bitrate and codec; nil when it can't be read.
    private static func describe(_ asset: AVAsset, video: AVAssetTrack, fileAt url: URL) async -> Source? {
        guard let (natural, transform, formats) = try? await video.load(.naturalSize, .preferredTransform, .formatDescriptions),
              let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0
        else { return nil }
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let bytes = fileSize(url) ?? 0
        let isH264 = formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }
        return Source(width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                      bitrate: Int(Double(bytes) * 8 / duration.seconds), isH264: isH264)
    }

    enum TranscodeError: LocalizedError {
        case cannotRead(String), cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .cannotRead(let why): return "can't read the video: \(why)"
            case .cannotWrite(let why): return "can't write the video: \(why)"
            }
        }
    }

    /// Decodes `video` (and the first audio track) and writes them as H.264/AAC at `width` × `height`.
    /// The video composition applies the rotation, scales, and converts HDR to SDR (BT.709).
    private static func transcode(_ asset: AVAsset, video: AVAssetTrack, to out: URL, width: Int, height: Int,
                                  bitrate: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (natural, transform, frameRate, minFrame) = try await video.load(.naturalSize, .preferredTransform,
                                                                             .nominalFrameRate, .minFrameDuration)
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio).first

        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let scale = CGFloat(width) / abs(shown.width)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(transform
            .concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = CGSize(width: width, height: height)
        composition.frameDuration = minFrame.isNumeric && minFrame.seconds > 0
            ? minFrame : CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 30)))
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        } catch {
            throw TranscodeError.cannotRead(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = []

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        let fps = frameRate > 0 ? Double(frameRate) : 30
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2
            ]
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else {
            throw TranscodeError.cannotWrite("video settings refused")
        }
        reader.add(videoOut)
        writer.add(videoIn)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput, Bool)] = [(videoOut, videoIn, true)]
        if let audio {
            let audioOut = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate
            ])
            audioIn.expectsMediaDataInRealTime = false
            // A clip whose sound can't be decoded still goes, silent, rather than not at all.
            if reader.canAdd(audioOut), writer.canAdd(audioIn) {
                reader.add(audioOut)
                writer.add(audioIn)
                pairs.append((audioOut, audioIn, false))
            }
        }

        guard reader.startReading() else {
            throw TranscodeError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw TranscodeError.cannotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
        writer.startSession(atSourceTime: .zero)

        let total = duration.seconds > 0 ? duration.seconds : 1
        let job = Job(reader: reader, writer: writer)
        try await withTaskCancellationHandler {
            // Each track pulls on its own queue as its input asks for more: appending both from one loop
            // can stall (the writer waits on the other track to interleave).
            await withTaskGroup(of: Void.self) { group in
                for (output, input, reportsProgress) in pairs {
                    group.addTask {
                        await pump(output, into: input, job: job) { time in
                            if reportsProgress { progress(min(1, max(0, time.seconds / total))) }
                        }
                    }
                }
            }
        } onCancel: {
            job.cancel()
        }
        if Task.isCancelled || job.isCancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.cannotRead(reader.error?.localizedDescription ?? "unknown error")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TranscodeError.cannotWrite(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }

    /// The reader and writer one transcode shares across its track queues, cancellable from any of them.
    private final class Job: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        private let lock = NSLock()
        private var cancelled = false

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            lock.withLock { cancelled = true }
            reader.cancelReading()
        }
    }

    /// Copies `output` into `input` as fast as `input` takes it; returns when the track is done.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, job: Job,
                             onSample: @escaping @Sendable (CMTime) -> Void) async {
        let queue = DispatchQueue(label: "nv.video-compressor.\(input.mediaType.rawValue)")
        let box = UncheckedBox(output: output, input: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            box.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while box.input.isReadyForMoreMediaData {
                    guard !job.isCancelled, job.reader.status == .reading,
                          let sample = box.output.copyNextSampleBuffer() else {
                        finished = true
                        box.input.markAsFinished()
                        done.resume()
                        return
                    }
                    onSample(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !box.input.append(sample) {
                        job.cancel()
                        finished = true
                        box.input.markAsFinished()
                        done.resume()
                        return
                    }
                }
            }
        }
    }

    private struct UncheckedBox: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }
}
