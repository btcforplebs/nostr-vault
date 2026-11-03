import SwiftUI
import AVFoundation
import ImageIO

/// Review a picture or video post the share sheet queued, then publish it.
/// Nothing uploads until Publish: the pictures go to the outside media
/// servers and the post to the relays only then.
struct MediaPostReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var title = ""
    @State private var caption = ""
    @State private var thumbs: [String: CGImage] = [:]
    @State private var step: MediaPostShareHandler.Step?
    @State private var error: String?

    private var npub: String { ShareAccountSection.account(for: intent) }
    private var shape: Result<MediaPostShareTags.Shape, MediaPostShareTags.Problem> { MediaPostShareHandler.shape(of: intent) }
    private var isVideo: Bool { (try? shape.get()) == .video }
    private var canPublish: Bool {
        _ = config.config.activeAccountNpub  // re-evaluate on account switch
        return step == nil && (try? shape.get()) != nil && ShareAccountSection.canAct(as: npub)
    }

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(intent.files, id: \.name) { file in thumb(file) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if case .failure(let problem) = shape {
                    Label(problem.message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text(isVideo ? "Video" : intent.files.count == 1 ? "Picture" : "\(intent.files.count) pictures")
            }
            Section {
                TextField(isVideo ? "Title (first line of the caption if empty)" : "Title (optional)", text: $title)
                TextField("Caption", text: $caption, axis: .vertical)
                    .lineLimit(3...8)
            }
            ShareAccountSection(npub: npub)
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button(action: publish) {
                    HStack {
                        Spacer()
                        switch step {
                        case .uploading(let done, let of):
                            ProgressView()
                            Text(of > 1 ? "Uploading \(done + 1) of \(of)…" : "Uploading…").padding(.leading, 6)
                        case .signing:
                            ProgressView()
                            Text("Posting…").padding(.leading, 6)
                        case nil:
                            Text("Publish").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(!canPublish)
            } footer: {
                Text("Posts are public. Where a picture was taken is removed before it uploads.")
            }
        }
        .onAppear {
            if title.isEmpty, caption.isEmpty { caption = intent.form["caption"] ?? "" }
        }
        .task { await loadThumbs() }
    }

    private func thumb(_ file: NVShareIntent.File) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15))
            if let image = thumbs[file.name] {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: MediaPostShareTags.isVideo(file.mime) ? "film" : "photo").foregroundStyle(.secondary)
            }
            if MediaPostShareTags.isVideo(file.mime) {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.white).shadow(radius: 2)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(MediaPostShareTags.isVideo(file.mime) ? "Video" : "Picture")
    }

    private func loadThumbs() async {
        for entry in MediaPostShareHandler.files(of: intent) where thumbs[entry.file.name] == nil {
            let image = await Self.thumbnail(entry.url, video: MediaPostShareTags.isVideo(entry.file.mime))
            if let image { thumbs[entry.file.name] = image }
        }
    }

    /// A small preview, read without decoding the full picture.
    nonisolated static func thumbnail(_ url: URL, video: Bool) async -> CGImage? {
        if video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 300)
            return try? await generator.image(at: .zero).image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 300]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func publish() {
        guard let lock = ShareAccountSection.lock(npub) else { return }
        error = nil
        step = .uploading(done: 0, of: intent.files.count)
        let title = title, caption = caption
        Task {
            do {
                try await MediaPostShareHandler.publish(intent, title: title, caption: caption, lockedTo: lock) { step = $0 }
                close()
            } catch {
                self.error = error.localizedDescription
                step = nil
            }
        }
    }
}
