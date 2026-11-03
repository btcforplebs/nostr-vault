import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Picture or video post (Share Portal, lane B): the photos or the video the
/// share sheet queued become one NIP-68 picture post (kind 20) or one NIP-71
/// video (kind 21, 22 when portrait). Nothing uploads until Publish on the
/// review card.
struct MediaPostShareHandler: SharePortalHandler {
    let action = NVShareAction.mediaPost

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(MediaPostReviewView(intent: intent, close: close))
    }
}

extension MediaPostShareHandler {
    /// The shared files on disk, in the order shared. Missing ones are left
    /// out (the card counts what it has).
    @MainActor
    static func files(of intent: NVShareIntent) -> [(file: NVShareIntent.File, url: URL)] {
        intent.files.compactMap { f in SharePortalInbox.shared.fileURL(for: f, of: intent).map { (f, $0) } }
    }

    static func shape(of intent: NVShareIntent) -> Result<MediaPostShareTags.Shape, MediaPostShareTags.Problem> {
        MediaPostShareTags.shape(mimes: intent.files.map(\.mime))
    }

    enum Step: Equatable {
        case uploading(done: Int, of: Int)
        case signing
    }

    /// Uploads each file to the outside media servers, then signs and sends
    /// the post as `lock`'s account. Throws with a message for the card.
    @MainActor
    static func publish(_ intent: NVShareIntent, title: String, caption: String, lockedTo lock: PostingAccount.Lock,
                        step: @escaping (Step) -> Void) async throws {
        let shape = try shape(of: intent).get()
        let files = files(of: intent)
        guard files.count == intent.files.count else {
            throw ModePostPublisher.PublishError.upload("A shared file is missing. Share it again.")
        }
        var media: [MediaPostShareTags.Media] = []
        for (index, entry) in files.enumerated() {
            step(.uploading(done: index, of: files.count))
            media.append(try await upload(entry.url, mime: entry.file.mime))
        }
        step(.signing)
        let tags = MediaPostShareTags.tags(shape, media: media, title: title, caption: caption,
                                           publishedAt: Int(Date().timeIntervalSince1970))
        try await ModePostPublisher.publish(kind: MediaPostShareTags.kind(shape, media: media),
                                            content: MediaPostShareTags.content(caption: caption),
                                            tags: tags, nostrService: NostrService.shared, lockedTo: lock)
    }

    /// One file up, described for its `imeta`. Pictures NIP-68 doesn't list
    /// (HEIC from the camera) go up as JPEG; the location comes out in
    /// ModePostPublisher.upload either way.
    @MainActor
    private static func upload(_ url: URL, mime: String) async throws -> MediaPostShareTags.Media {
        var fileURL = url
        var type = mime.lowercased()
        var converted: URL?
        defer { if let converted { try? FileManager.default.removeItem(at: converted) } }
        if MediaPostShareTags.needsJPEG(type) {
            guard let jpeg = jpegCopy(of: url) else {
                throw ModePostPublisher.PublishError.upload("Couldn't turn a picture into a JPEG to post it.")
            }
            converted = jpeg
            fileURL = jpeg
            type = "image/jpeg"
        }
        let blob = try await ModePostPublisher.upload(fileURL: fileURL, mimeType: type, configService: ConfigService.shared,
                                                      nostrService: NostrService.shared)
        var size: CGSize?
        var duration: Double?
        if MediaPostShareTags.isVideo(type) {
            size = await ComposeView.pixelSize(ofVideoAt: fileURL)
            if let time = try? await AVURLAsset(url: fileURL).load(.duration), time.isNumeric {
                duration = time.seconds
            }
        } else if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            size = ComposeView.pixelSize(ofImageData: data)
        }
        return MediaPostShareTags.Media(url: blob.url.absoluteString, mime: type, sha256: blob.sha256,
                                        width: size.map { Int($0.width) }, height: size.map { Int($0.height) },
                                        bytes: blob.byteCount, duration: duration, alt: nil)
    }

    /// A JPEG of the picture at `url` (first frame), metadata kept so the
    /// orientation survives. A temporary file the caller deletes.
    nonisolated static func jpegCopy(of url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dest, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }
}
