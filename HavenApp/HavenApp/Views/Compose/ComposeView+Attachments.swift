import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
import AVFoundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

extension ComposeView {
    func loadSelectedItems() {
        for item in selectedItems {
            // Check ALL supported content types — .first can be a non-video type
            // even for videos (e.g. HEVC, iCloud items, combined pickers).
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let contentType = item.supportedContentTypes.first ?? .image

            if isVideo {
                loadVideoItem(item, contentType: contentType)
            } else {
                loadImageItem(item, contentType: contentType)
            }
        }
        selectedItems = []
    }

    private func loadVideoItem(_ item: PhotosPickerItem, contentType: UTType) {
        Task {
            // Try file-based ImportedVideoFile first, fall back to Data if the system
            // can't provide a .movie file representation (HEVC transcoding, iCloud, etc.).
            if let video = try? await item.loadTransferable(type: ImportedVideoFile.self) {
                let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                let videoURL = video.url
                let thumbnail = await self.generateVideoThumbnail(url: videoURL)
                await MainActor.run {
                    self.appendAttachment(Attachment(
                        data: nil,
                        fileURL: videoURL,
                        type: derivedType,
                        thumbnail: thumbnail
                    ))
                }
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                // Fallback: write bytes to temp file so the upload can stream from disk.
                let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) } ?? contentType
                let ext = videoType.preferredFilenameExtension ?? "mp4"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                do {
                    try data.write(to: dest)
                    let derivedType = UTType(filenameExtension: ext) ?? videoType
                    let thumbnail = await self.generateVideoThumbnail(url: dest)
                    await MainActor.run {
                        self.appendAttachment(Attachment(
                            data: nil,
                            fileURL: dest,
                            type: derivedType,
                            thumbnail: thumbnail
                        ))
                    }
                } catch {
                    await MainActor.run {
                        self.error = "Failed to load video: \(error.localizedDescription)"
                    }
                }
            } else {
                await MainActor.run {
                    self.error = "Failed to load video file."
                }
            }
        }
    }

    private func loadImageItem(_ item: PhotosPickerItem, contentType: UTType) {
        item.loadTransferable(type: Data.self) { result in
            switch result {
            case .success(let data):
                guard let data = data else { return }
                DispatchQueue.main.async {
                    self.addImageData(data, type: contentType)
                }
            case .failure(let error):
                #if DEBUG
                print("Failed to load media: \(error)")
                #endif
                DispatchQueue.main.async {
                    self.error = "Failed to load media: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Attaches dragged-in media in the order it was dropped, as far as the
    /// note has room; the rest meets the attachment limit's message.
    @MainActor
    func attachDropped(_ providers: [NSItemProvider]) async {
        var loaded: [DroppedMedia] = []
        for provider in providers.prefix(remainingAttachmentSlots + 1) {
            if let media = await DroppedMedia.load(provider, acceptingVideo: true) { loaded.append(media) }
        }
        guard !loaded.isEmpty else {
            error = "Couldn't read what was dropped."
            return
        }
        for media in loaded {
            switch media {
            case .image(let data, let type):
                addImageData(data, type: type)
            case .video(let url, let type):
                let thumbnail = await generateVideoThumbnail(url: url)
                appendAttachment(Attachment(data: nil, fileURL: url, type: type, thumbnail: thumbnail))
            }
        }
    }

    /// An image from the photo picker or a drop: HEIC becomes JPEG, as the
    /// readers of a note expect; everything else keeps its bytes.
    private func addImageData(_ data: Data, type contentType: UTType) {
        var finalData = data
        var finalType = contentType

        // Convert HEIC/HEIF to JPEG
        if contentType.conforms(to: .heic) || contentType.conforms(to: .heif) {
            #if os(iOS)
            if let image = UIImage(data: data),
               let jpegData = image.jpegData(compressionQuality: 0.8) {
                finalData = jpegData
                finalType = .jpeg
            }
            #elseif os(macOS)
            if let image = NSImage(data: data),
               let tiffData = image.tiffRepresentation,
               let bitmapRep = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                finalData = jpegData
                finalType = .jpeg
            }
            #endif
        }

        self.appendAttachment(Attachment(
            data: finalData,
            fileURL: nil,
            type: finalType,
            thumbnail: nil
        ))
    }
    
    /// Computes the SHA256 of a file by streaming it in 1 MB chunks so large
    /// videos don't sit fully in memory.
    nonisolated static func streamingSHA256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    /// The Blossom SHA-256 a blob URL is named by, if its last path component
    /// is one (`<64 hex>` or `<64 hex>.<ext>`).
    nonisolated static func blossomHash(in url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return name.count == 64 && name.allSatisfy(\.isHexDigit) ? name : nil
    }

    /// Pixel dimensions of encoded image bytes, read from the image's own
    /// header rather than by decoding it — an `imeta dim` is worth one header
    /// read, not a full decode of a 12-megapixel photo.
    nonisolated static func pixelSize(ofImageData data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Displayed dimensions of a video track: `naturalSize` is pre-rotation, so
    /// a portrait clip shot on a phone reports landscape unless the track's
    /// preferred transform is applied. Getting this backwards would reserve a
    /// sideways box in every client that trusts our `dim`.
    nonisolated static func pixelSize(ofVideoAt url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let oriented = naturalSize.applying(transform)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// How many attachments one note carries. The editor's grid, the upload
    /// progress copy and every reader's media layout assume a small number.
    static let maxAttachments = 4

    /// Adds an attachment unless the note is already full.
    ///
    /// The picker paths used to append unconditionally: `maxSelectionCount`
    /// floors at 1, so a note already holding four could still take a fifth,
    /// and nothing ever told the author there was a limit — they met it as
    /// buttons that stopped responding.
    @discardableResult
    private func appendAttachment(_ attachment: Attachment) -> Bool {
        guard attachments.count < Self.maxAttachments else {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            error = "A note can carry \(Self.maxAttachments) attachments."
            return false
        }
        attachments.append(attachment)
        // Its link goes in where the caret is now, once the upload lands.
        note.anchors[attachment.id] = min(note.selection.location + note.selection.length, content.utf16.count)
        // Behind another upload: sign its authorisation while it waits. The
        // first one signs its own straight away; preparing it too would ask
        // a remote signer twice.
        if note.unfinishedUploads > 1 { prepareUploadAuth(for: attachment) }
        startUpload(for: attachment.id)
        return true
    }

    /// Signs the attachment's Blossom upload authorisation while the author is
    /// still writing.
    ///
    /// Posting a photo used to cost two signer round trips back to back — the
    /// authorisation, then the note — and a four-photo note five, all of them
    /// after the tap. The hash is the only thing the authorisation is scoped
    /// to and it is known the moment the file is attached, so the signer can
    /// answer for it now; `BlossomService` hands the stored answer to the
    /// upload. Nothing depends on it finishing: the upload path signs its own
    /// if this has not landed.
    private func prepareUploadAuth(for attachment: Attachment) {
        let blossom = blossomService
        if let data = attachment.data {
            Task.detached(priority: .utility) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                blossom.prepareUploadAuth(sha256: hash)
            }
        } else if let fileURL = attachment.fileURL {
            Task.detached(priority: .utility) {
                guard let hash = ComposeView.streamingSHA256(of: fileURL) else { return }
                blossom.prepareUploadAuth(sha256: hash)
            }
        }
        // Media already on the relay carries neither: it is not uploaded, so
        // it needs no authorisation.
    }

    /// Attaches media that already lives on the relay. It shows in the
    /// attachment strip like a fresh upload, but posting skips the upload and
    /// publishes its existing URL.
    func attachRelayMedia(_ item: MediaItem) {
        let type: UTType
        if let mime = item.mimeType, let t = UTType(mimeType: mime) {
            type = t
        } else if item.isAnimatedGIF {
            type = .gif
        } else {
            switch item.type {
            case .video: type = .movie
            case .audio: type = .audio
            default: type = .image
            }
        }
        appendAttachment(Attachment(
            data: nil,
            fileURL: nil,
            type: type,
            url: item.shareURL(with: configService),
            isUploaded: true,
            relayBlobFile: configService.relayDataDir
                .appendingPathComponent(configService.config.blossomPath)
                .appendingPathComponent(item.url.lastPathComponent)
        ))
    }

    /// The composer closed: stop uploads still going and drop the temp copies.
    func cleanupAttachmentTempFiles() {
        for task in note.uploads.values { task.cancel() }
        for attachment in attachments {
            if let fileURL = attachment.fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func generateVideoThumbnail(url: URL) async -> PlatformImage? {
        await withCheckedContinuation { continuation in
            let asset = AVAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            let time = CMTime(seconds: 0.0, preferredTimescale: 600)
            imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, error in
                if let cgImage = cgImage {
                    #if os(macOS)
                    continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    #else
                    continuation.resume(returning: UIImage(cgImage: cgImage))
                    #endif
                } else {
                    #if DEBUG
                    if let error = error {
                        print("Error generating video thumbnail: \(error)")
                    }
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Downloads a picked GIF and adds it as an attachment. Each source
    /// downloads through its own client so the size cap and the GIF-magic
    /// check stay with the service that knows the host.
    func attachGif(_ item: GifItem) {
        // nostr.build GIFs are already hosted: post the link unless the user
        // asked to keep a copy on their own Blossom servers.
        if item.source == .nostrBuild && !ConfigService.shared.config.saveGifsToBlossom {
            // In at the caret, like a photo's link.
            let caret = min(note.selection.location + note.selection.length, content.utf16.count)
            note.appEdited = true
            content = ComposerPlacement.insert(item.attachURL.absoluteString, at: caret, in: content).text
            return
        }
        guard !isAttachmentLimitReached, !isFetchingGif else { return }
        isFetchingGif = true
        Task {
            do {
                let data: Data
                var type: UTType = .gif
                switch item.source {
                case .nostrBuild:
                    let file = try await NostrBuildGifService.download(item.attachURL)
                    data = file.data
                    if file.isWebP { type = .webP }
                case .tenor:
                    #if TENOR_SIDELOAD
                    data = try await TenorGifService.downloadGIF(url: item.attachURL)
                    #else
                    throw URLError(.unsupportedURL)
                    #endif
                }
                await MainActor.run {
                    appendAttachment(Attachment(data: data, fileURL: nil, type: type))
                    isFetchingGif = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Could not fetch GIF: \(error.localizedDescription)"
                    isFetchingGif = false
                }
            }
        }
    }

    func handlePasteFromClipboard() {
        guard !isAttachmentLimitReached, !isPastingVideo else { return }

        // A video first, as the Media tab's Magic Paste does: a clip copied in
        // Photos, here or on another device over Universal Clipboard, can
        // come with a still frame beside it, and the image branch would
        // attach that frame instead of the video.
        if PlatformClipboard.hasVideo() {
            isPastingVideo = true
            Task {
                let video = await PlatformClipboard.copyVideoToTemporaryFile()
                let thumbnail: PlatformImage? = if let video { await generateVideoThumbnail(url: video) } else { nil }
                await MainActor.run {
                    isPastingVideo = false
                    guard let video else {
                        error = "Couldn't read the video on the clipboard."
                        return
                    }
                    let type = UTType(filenameExtension: video.pathExtension) ?? .movie
                    appendAttachment(Attachment(data: nil, fileURL: video, type: type, thumbnail: thumbnail))
                }
            }
            return
        }

        if PlatformClipboard.hasImage(), let imageData = PlatformClipboard.getImageData() {
            // Detect actual image format from data magic bytes
            let detectedType: UTType
            if imageData.count >= 6 {
                let gif87 = Data("GIF87a".utf8)
                let gif89 = Data("GIF89a".utf8)
                let prefix = imageData.prefix(6)
                if prefix == gif87 || prefix == gif89 {
                    detectedType = .gif
                } else if imageData.prefix(4) == Data([137, 80, 78, 71]) { // PNG magic
                    detectedType = .png
                } else {
                    detectedType = .jpeg
                }
            } else {
                detectedType = .jpeg
            }
            appendAttachment(Attachment(
                data: imageData,
                fileURL: nil,
                type: detectedType
            ))
        } else if let clipboardString = PlatformClipboard.getString() {
            let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pasted = URL(string: trimmed),
               (pasted.scheme == "http" || pasted.scheme == "https") {
                let url = pasted
                let ext = url.pathExtension.lowercased()
                let hasKnownExt = SupportedMediaFormats.allExtensions.contains(ext)
                // Media URL — download and add as attachment
                Task {
                    guard let (data, response) = try? await URLSession.shared.data(from: url) else {
                        await MainActor.run { error = "Failed to download media from URL" }
                        return
                    }
                    // Determine the media type from extension, or fall back to Content-Type
                    let httpResponse = response as? HTTPURLResponse
                    let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    let resolvedExt: String
                    if hasKnownExt {
                        resolvedExt = ext
                    } else if let mimeExt = SupportedMediaFormats.extension(forMime: contentType) {
                        resolvedExt = mimeExt
                    } else if !hasKnownExt {
                        // Not a recognized media URL
                        await MainActor.run { error = "Clipboard does not contain an image or media URL" }
                        return
                    } else {
                        resolvedExt = ext
                    }
                    let isVideo = SupportedMediaFormats.videoExtensions.contains(resolvedExt)
                    if isVideo {
                        let tempURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("haven-paste-\(UUID().uuidString)")
                            .appendingPathExtension(resolvedExt)
                        try? data.write(to: tempURL)
                        let thumbnail = await generateVideoThumbnail(url: tempURL)
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .mpeg4Movie
                        await MainActor.run {
                            appendAttachment(Attachment(
                                data: nil,
                                fileURL: tempURL,
                                type: derivedType,
                                thumbnail: thumbnail
                            ))
                        }
                    } else {
                        let derivedType = UTType(filenameExtension: resolvedExt) ?? .jpeg
                        await MainActor.run {
                            appendAttachment(Attachment(
                                data: data,
                                fileURL: nil,
                                type: derivedType
                            ))
                        }
                    }
                }
            } else {
                error = "Clipboard does not contain an image or media URL"
            }
        } else {
            error = "Clipboard is empty"
        }
    }
}
