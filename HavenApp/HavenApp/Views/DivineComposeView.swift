import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Posts a diVine: a short looping video published as a NIP-71 addressable
/// short-video event (kind 34236), shaped like the ones diVine's own app
/// publishes, and sent to diVine's relay as well as the owner's.
struct DivineComposeView: View {
    var onDismiss: () -> Void
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    /// diVine's camera records six-second loops; longer picked videos are
    /// trimmed to their opening this long.
    static let recordLimit: TimeInterval = 6.3
    /// How long to wait for diVine's relay to accept the post.
    static let divineRelayDeadline: TimeInterval = 15

    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var clip: PreparedClip?
    @State private var isPreparing = false
    @State private var title = ""
    @State private var caption = ""
    @State private var isPosting = false
    @State private var status: String?
    @State private var error: String?
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    videoArea
                    if clip != nil {
                        lengthMeter
                    }
                    if !isPosting {
                        sourceButtons
                    }
                    if clip != nil {
                        fields
                    }
                    if let status {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(status).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("New diVine")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                        .disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { post() } label: {
                        Text("Post").fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.havenPurple)
                    .disabled(clip == nil || isPosting || isPreparing)
                }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await importPicked(item) }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingCamera) {
            VideoCameraPicker(maxDuration: Self.recordLimit) { url in
                showingCamera = false
                if let url { Task { await prepare(url) } }
            }
            .ignoresSafeArea()
        }
        #endif
        .onDisappear { player?.pause() }
        .interactiveDismissDisabled(isPosting)
    }

    // MARK: - Pieces

    /// The one rule a diVine has, said before anything is picked.
    private var header: some View {
        VStack(spacing: 4) {
            Text("A looping video, up to \(Self.limitSeconds) seconds")
                .font(.headline)
            Text("Record one, or choose a video. Longer videos keep their first \(Self.limitSeconds) seconds.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// Whole seconds a diVine can run, as people say it.
    static var limitSeconds: Int { Int(recordLimit) }

    private var videoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
            if let player {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if isPreparing {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Getting the video ready…").font(.footnote).foregroundColor(.white.opacity(0.8))
                }
            } else {
                VStack(spacing: 6) {
                    Text("\(Self.limitSeconds)s")
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("max length")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Up to \(Self.limitSeconds) seconds")
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxHeight: 420)
    }

    /// How much of the limit the picked clip uses.
    @ViewBuilder
    private var lengthMeter: some View {
        if let clip {
            let used = min(1, clip.duration / Double(Self.limitSeconds))
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(Color.havenPurple)
                            .frame(width: max(8, geo.size.width * used))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text(String(format: "%.1fs of %ds", clip.duration, Self.limitSeconds))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    Spacer()
                    Text(clip.wasTrimmed ? "Trimmed to fit" : "Fits")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: 420)
            .accessibilityElement(children: .combine)
        }
    }

    private var sourceButtons: some View {
        // Stacked and large while they are the next step; a compact row once
        // there is a clip and Post is.
        let layout = clip == nil ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            #if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                // Filled until there is a clip; after that Post is the next step.
                if clip == nil {
                    Button { showingCamera = true } label: {
                        Label("Record a video", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { showingCamera = true } label: {
                        Label("Record again", systemImage: "video.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            #endif
            PhotosPicker(selection: $pickerItem, matching: .videos) {
                Label(clip == nil ? "Choose from Photos" : "Choose another",
                      systemImage: "photo.on.rectangle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .tint(.havenPurple)
        .controlSize(clip == nil ? .large : .regular)
        .frame(maxWidth: 420)
        .disabled(isPreparing)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("Caption (optional) — #tags work", text: $caption, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
        }
        .disabled(isPosting)
    }

    // MARK: - Preparing

    private func importPicked(_ item: PhotosPickerItem) async {
        isPreparing = true
        error = nil
        guard let video = try? await item.loadTransferable(type: ImportedVideoFile.self) else {
            isPreparing = false
            error = "Couldn't load that video."
            return
        }
        await prepare(video.url)
    }

    /// Re-encodes to H.264 MP4 — iPhone footage is HEVC in a .mov, which
    /// diVine's web and Android players can't count on — and grabs a poster.
    private func prepare(_ source: URL) async {
        isPreparing = true
        error = nil
        player?.pause()
        player = nil
        looper = nil
        do {
            let prepared = try await PreparedClip.make(from: source)
            try? FileManager.default.removeItem(at: source)
            clip?.cleanUp()
            clip = prepared
            let item = AVPlayerItem(url: prepared.videoURL)
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()
        } catch {
            self.error = error.localizedDescription
        }
        isPreparing = false
    }

    // MARK: - Posting

    private func post() {
        guard let clip else { return }
        isPosting = true
        error = nil
        player?.pause()
        Task {
            do {
                status = "Uploading video…"
                let video = try await ModePostPublisher.upload(
                    fileURL: clip.videoURL, mimeType: "video/mp4",
                    configService: configService, nostrService: nostrService,
                    progress: { fraction in
                        Task { @MainActor in status = "Uploading video… \(Int(fraction * 100))%" }
                    })
                status = "Uploading cover…"
                let poster = try await ModePostPublisher.upload(
                    data: clip.posterJPEG, mimeType: "image/jpeg",
                    configService: configService, nostrService: nostrService)

                status = "Posting…"
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                let tags = Self.tags(video: video, posterURL: poster.url, clip: clip,
                                     title: trimmedTitle, caption: trimmedCaption,
                                     publishedAt: Int(Date().timeIntervalSince1970))

                // The relay's own timeout only starts once its socket connects,
                // so a socket stuck connecting would never report; stop waiting
                // after a deadline of our own.
                let once = ResumeOnce()
                let divineResult = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, String)?, Never>) in
                    Task {
                        try? await Task.sleep(for: .seconds(Self.divineRelayDeadline))
                        if once.claim() { continuation.resume(returning: (false, "it didn't answer")) }
                    }
                    Task {
                        do {
                            try await ModePostPublisher.publish(
                                kind: 34236, content: trimmedCaption, tags: tags,
                                extraRelays: [ReelsFeedService.divineRelay],
                                nostrService: nostrService
                            ) { relay, ok, message in
                                guard relay == ReelsFeedService.divineRelay, once.claim() else { return }
                                continuation.resume(returning: (ok, message))
                            }
                        } catch {
                            guard once.claim() else { return }
                            self.error = error.localizedDescription
                            continuation.resume(returning: nil)
                        }
                    }
                }
                guard let (accepted, message) = divineResult else {
                    status = nil
                    isPosting = false
                    return
                }
                if !accepted {
                    ErrorNotificationManager.shared.show(
                        "Posted to your relays, but diVine's relay didn't take it: \(message.isEmpty ? "no reason given" : message)",
                        style: .warning)
                }
                clip.cleanUp()
                ReelsFeedService.shared.refresh()
                status = nil
                isPosting = false
                onDismiss()
            } catch {
                status = nil
                isPosting = false
                self.error = error.localizedDescription
            }
        }
    }

    /// Tags in the order and shape diVine's own events use.
    static func tags(video: ModePostPublisher.UploadedBlob, posterURL: URL, clip: PreparedClip,
                     title: String, caption: String, publishedAt: Int) -> [[String]] {
        var tags: [[String]] = [["d", video.sha256]]
        tags.append([
            "imeta",
            "url \(video.url.absoluteString)",
            "m video/mp4",
            "image \(posterURL.absoluteString)",
            "dim \(Int(clip.size.width))x\(Int(clip.size.height))",
            "x \(video.sha256)",
            "size \(video.byteCount)"
        ])
        if !title.isEmpty {
            tags.append(["title", title])
        }
        tags.append(["published_at", String(publishedAt)])
        tags.append(["duration", String(max(1, Int(clip.duration.rounded())))])
        tags.append(["alt", title.isEmpty ? (caption.isEmpty ? "Short video" : String(caption.prefix(140))) : title])
        tags.append(contentsOf: NoteTagging.hashtagTags(in: "\(title) \(caption)"))
        return tags
    }

    private func close() {
        player?.pause()
        clip?.cleanUp()
        onDismiss()
    }
}

/// A video re-encoded for posting, with what its event needs to say about it.
struct PreparedClip {
    let videoURL: URL
    let posterJPEG: Data
    /// Displayed (rotation-applied) pixel size.
    let size: CGSize
    let duration: TimeInterval
    /// The source ran past `DivineComposeView.recordLimit` and was cut.
    let wasTrimmed: Bool

    enum PrepareError: LocalizedError {
        case noVideoTrack, exportFailed(String), noPoster
        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "That file has no video in it."
            case .exportFailed(let why): return "Couldn't convert the video: \(why)"
            case .noPoster: return "Couldn't read a frame from the video."
            }
        }
    }

    static func make(from source: URL) async throws -> PreparedClip {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw PrepareError.noVideoTrack }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("divine-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw PrepareError.exportFailed("no exporter")
        }
        session.shouldOptimizeForNetworkUse = true
        let limit = CMTime(seconds: DivineComposeView.recordLimit, preferredTimescale: 600)
        let wasTrimmed = try await asset.load(.duration) > limit
        if wasTrimmed {
            session.timeRange = CMTimeRange(start: .zero, duration: limit)
        }
        if #available(iOS 18, macOS 15, *) {
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                throw PrepareError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
            guard session.status == .completed else {
                throw PrepareError.exportFailed(session.error?.localizedDescription ?? "unknown error")
            }
        }

        let exported = AVURLAsset(url: output)
        let duration = try await exported.load(.duration).seconds
        let size = await ComposeView.pixelSize(ofVideoAt: output) ?? CGSize(width: 1080, height: 1920)

        let generator = AVAssetImageGenerator(asset: exported)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1080)
        let time = CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)
        let frame = try await generator.image(at: time).image
        guard let jpeg = Self.jpegData(frame) else { throw PrepareError.noPoster }

        return PreparedClip(videoURL: output, posterJPEG: jpeg, size: size, duration: duration, wasTrimmed: wasTrimmed)
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: videoURL)
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

#if os(iOS)
/// The system camera, video only, capped at `maxDuration` seconds.
struct VideoCameraPicker: UIViewControllerRepresentable {
    let maxDuration: TimeInterval
    let onFinish: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.movie"]
        picker.cameraCaptureMode = .video
        picker.videoMaximumDuration = maxDuration
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let recorded = info[.mediaURL] as? URL else { onFinish(nil); return }
            // The recording lives in a picker-owned temp file; keep our own copy.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("divine-rec-\(UUID().uuidString)")
                .appendingPathExtension(recorded.pathExtension.isEmpty ? "mov" : recorded.pathExtension)
            do {
                try FileManager.default.copyItem(at: recorded, to: copy)
                onFinish(copy)
            } catch {
                onFinish(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
#endif
