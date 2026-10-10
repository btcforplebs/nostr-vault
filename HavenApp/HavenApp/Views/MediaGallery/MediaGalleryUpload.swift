import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import CryptoKit
#if os(iOS)
import Photos
#endif

// MARK: - Upload & Media Management

extension MediaGalleryView {

    func triggerAutoMirrorIfEnabled() {
        guard configService.config.autoMirrorMedia else { return }
        MirrorService.shared.runMirror(configService: configService, nostrService: nostrService)
    }

    #if os(iOS)
    func saveMediaToPhotos(item: MediaItem) {
        saveToPhotosMessage = nil

        Task {
            // Request photo library permission
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    saveToPhotosMessage = "Photo library access denied"
                }
                return
            }

            // Download media data
            let session = URLSession(configuration: .default, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
            do {
                let (data, _) = try await session.data(from: item.url)

                if item.type == .video {
                    // Videos need a temp file
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
                    try data.write(to: tempURL)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tempURL, options: nil)
                    }
                    try? FileManager.default.removeItem(at: tempURL)
                } else {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        request.addResource(with: .photo, data: data, options: options)
                    }
                }

                await MainActor.run {
                    withAnimation { saveToPhotosMessage = "Saved to Photos" }
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { withAnimation { saveToPhotosMessage = nil } }
                    }
                }
            } catch {
                await MainActor.run {
                    saveToPhotosMessage = "Failed to save"
                }
                print("Save to Photos error: \(error.localizedDescription)")
            }
        }
    }
    #endif

    func handleUploadSelectedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }

        let blossom = blossomService

        for item in items {
            // Check ALL supported content types — .first can be a non-video type
            // even for videos (e.g. combined picker, HEVC, iCloud items).
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            let contentType = item.supportedContentTypes.first ?? .image

            let filename = "media-\(UUID().uuidString.prefix(8))"

            // Create a structured task and store it to keep it alive
            let uploadTask = Task {
                let notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: filename)
                }

                if isVideo {
                    // Handle video upload — try file-based ImportedVideoFile first,
                    // fall back to Data if the system can't provide a .movie file
                    // representation (HEVC transcoding failure, iCloud-only items, etc.).
                    do {
                        var fileURL: URL?
                        var mimeType = "video/mp4"

                        if let video = try? await item.loadTransferable(type: ImportedVideoFile.self) {
                            let derivedType = UTType(filenameExtension: video.url.pathExtension) ?? contentType
                            mimeType = derivedType.preferredMIMEType ?? "video/mp4"
                            fileURL = video.url
                        } else if let data = try await item.loadTransferable(type: Data.self) {
                            // Fallback: write raw bytes to a temp file so we can stream the upload.
                            // Determine MIME from the first video-conformant supported type.
                            let videoType = item.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                            let ext = videoType?.preferredFilenameExtension ?? "mp4"
                            mimeType = videoType?.preferredMIMEType ?? "video/mp4"
                            let dest = FileManager.default.temporaryDirectory
                                .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                                .appendingPathExtension(ext)
                            try data.write(to: dest)
                            fileURL = dest
                        }

                        guard var fileURL else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read video file.")
                            }
                            return
                        }

                        // Never upload where it was taken (MediaPrivacy).
                        guard let cleanURL = await MediaPrivacy.removingLocation(fromFileAt: fileURL) else {
                            try? FileManager.default.removeItem(at: fileURL)
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: MediaPrivacy.failureMessage)
                            }
                            return
                        }
                        if cleanURL != fileURL {
                            try? FileManager.default.removeItem(at: fileURL)
                            fileURL = cleanURL
                        }

                        guard let sha256 = ComposeView.streamingSHA256(of: fileURL) else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to compute SHA256.")
                            }
                            try? FileManager.default.removeItem(at: fileURL)
                            return
                        }

                        let localSuccess = await blossom.saveToLocalRelay(
                            fileURL: fileURL,
                            sha256: sha256,
                            contentType: mimeType
                        ) { progress in
                            Task { @MainActor in
                                MediaUploadNotificationManager.shared.updateProgress(id: notificationId, progress: progress)
                            }
                        }

                        try? FileManager.default.removeItem(at: fileURL)

                        await MainActor.run {
                            if localSuccess {
                                MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                                self.loadLocalMedia(force: true)
                            } else {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload video to local relay.")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: error.localizedDescription)
                        }
                    }
                } else {
                    // Handle image upload - use async loadTransferable
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read image data.")
                            }
                            return
                        }

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

                        // Never upload where it was taken (MediaPrivacy).
                        guard let cleanData = MediaPrivacy.removingLocation(fromImageData: finalData) else {
                            await MainActor.run {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: MediaPrivacy.failureMessage)
                            }
                            return
                        }
                        finalData = cleanData

                        let mimeType = finalType.preferredMIMEType ?? "image/jpeg"
                        let sha256 = SHA256.hash(data: finalData).map { String(format: "%02x", $0) }.joined()

                        let localSuccess = await blossom.saveToLocalRelay(
                            data: finalData,
                            sha256: sha256,
                            contentType: mimeType
                        )

                        await MainActor.run {
                            if localSuccess {
                                MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                                self.loadLocalMedia(force: true)
                            } else {
                                MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload image to local relay.")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: error.localizedDescription)
                        }
                    }
                }
            }

            // Store task to keep it alive
            activeUploadTasks.append(uploadTask)
        }

        // Clear selected items only AFTER creating all tasks
        self.selectedUploadItems = []

        // Clean up completed tasks periodically
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            activeUploadTasks.removeAll { $0.isCancelled || Task.isCancelled }
        }
    }

    func handleUploadFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let blossom = blossomService

        for url in urls {
            // Only a sandboxed build hands out security-scoped URLs. Elsewhere
            // this can return false for a perfectly readable file, which used to
            // skip the upload without a word.
            let scoped = url.startAccessingSecurityScopedResource()

            let filename = url.lastPathComponent

            Task { @MainActor in
                let notificationId = MediaUploadNotificationManager.shared.add(filename: filename)

                let derivedType = UTType(filenameExtension: url.pathExtension) ?? .item
                let mimeType = derivedType.preferredMIMEType ?? "application/octet-stream"

                Task {
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }

                    // Copy the file to a temp location so we can read it safely without sandbox errors during async operation
                    let tempDest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("haven-upload-\(UUID().uuidString)")
                        .appendingPathExtension(url.pathExtension)

                    do {
                        try? FileManager.default.removeItem(at: tempDest)
                        try FileManager.default.copyItem(at: url, to: tempDest)
                    } catch {
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to read file.")
                        }
                        return
                    }

                    // Never upload where it was taken (MediaPrivacy).
                    guard let uploadURL = await MediaPrivacy.removingLocation(fromFileAt: tempDest) else {
                        try? FileManager.default.removeItem(at: tempDest)
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: MediaPrivacy.failureMessage)
                        }
                        return
                    }
                    defer { if uploadURL != tempDest { try? FileManager.default.removeItem(at: uploadURL) } }

                    guard let sha256 = ComposeView.streamingSHA256(of: uploadURL) else {
                        try? FileManager.default.removeItem(at: tempDest)
                        await MainActor.run {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to compute SHA256.")
                        }
                        return
                    }

                    let localSuccess = await blossom.saveToLocalRelay(
                        fileURL: uploadURL,
                        sha256: sha256,
                        contentType: mimeType
                    ) { progress in
                        Task { @MainActor in
                            MediaUploadNotificationManager.shared.updateProgress(id: notificationId, progress: progress)
                        }
                    }

                    try? FileManager.default.removeItem(at: tempDest)

                    await MainActor.run {
                        if localSuccess {
                            MediaUploadNotificationManager.shared.markSuccess(id: notificationId)
                            loadLocalMedia(force: true)
                        } else {
                            MediaUploadNotificationManager.shared.markFailed(id: notificationId, message: "Failed to upload to local relay.")
                        }
                    }
                }
            }
        }
    }

    func handlePasteFromClipboard() {
        // Set loading state immediately
        isPastingContent = true
        Task {
            let blossom = blossomService
            var success = false
            var notificationId: UUID? = nil

            // SCENARIO 0: a video. Checked first because an app that copies a
            // clip may put a still frame next to it, and the image branch
            // would upload that frame instead. Handed to the file upload,
            // which streams from disk and shows the usual progress.
            if let video = await PlatformClipboard.copyVideoToTemporaryFile() {
                await MainActor.run {
                    isPastingContent = false
                    handleUploadFileURLs([video])
                }
                return
            }

            // SCENARIO 1: Check for image data first (higher priority)
            if PlatformClipboard.hasImage(), let pastedData = PlatformClipboard.getImageData() {
                // Never upload where it was taken (MediaPrivacy).
                guard let imageData = MediaPrivacy.removingLocation(fromImageData: pastedData) else {
                    await MainActor.run {
                        isPastingContent = false
                        ErrorNotificationManager.shared.show(MediaPrivacy.failureMessage, icon: "location.slash", style: .warning)
                    }
                    return
                }
                // Detect actual image format from magic bytes
                let detectedContentType: String
                if imageData.count >= 6 {
                    let prefix = imageData.prefix(6)
                    if prefix == Data("GIF87a".utf8) || prefix == Data("GIF89a".utf8) {
                        detectedContentType = "image/gif"
                    } else if imageData.prefix(4) == Data([137, 80, 78, 71]) {
                        detectedContentType = "image/png"
                    } else if imageData.prefix(4) == Data([82, 73, 70, 70]) && imageData.count >= 12 && imageData[8...11] == Data([87, 69, 66, 80]) {
                        detectedContentType = "image/webp"
                    } else {
                        detectedContentType = "image/jpeg"
                    }
                } else {
                    detectedContentType = "image/jpeg"
                }

                notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: "pasted-image")
                }

                let sha256 = SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined()

                success = await blossom.saveToLocalRelay(
                    data: imageData,
                    sha256: sha256,
                    contentType: detectedContentType
                )
            }
            // SCENARIO 2: Check for URL string
            else if let clipboardString = PlatformClipboard.getString() {
                let trimmed = clipboardString.trimmingCharacters(in: .whitespacesAndNewlines)

                guard let url = URL(string: trimmed),
                      url.scheme == "http" || url.scheme == "https" else {
                    await MainActor.run {
                        isPastingContent = false
                        ErrorNotificationManager.shared.show(
                            String(localized: "media.paste.error.notAURL"),
                            icon: "doc.on.clipboard",
                            style: .warning
                        )
                    }
                    return
                }

                let filename = url.lastPathComponent.isEmpty
                    ? "media-\(UUID().uuidString.prefix(8))"
                    : url.lastPathComponent

                notificationId = await MainActor.run {
                    MediaUploadNotificationManager.shared.add(filename: filename)
                }

                // Use existing BlossomService.downloadFromURL
                success = await blossom.downloadFromURL(url: url)
            }
            else {
                // Clipboard is empty or unsupported content
                await MainActor.run {
                    isPastingContent = false
                    ErrorNotificationManager.shared.show(
                        String(localized: "media.paste.error.empty"),
                        icon: "doc.on.clipboard",
                        style: .warning
                    )
                }
                return
            }

            // Update UI on main thread
            await MainActor.run {
                isPastingContent = false

                if success, let id = notificationId {
                    MediaUploadNotificationManager.shared.markSuccess(id: id)
                    loadLocalMedia(force: true)
                } else if let id = notificationId {
                    MediaUploadNotificationManager.shared.markFailed(
                        id: id,
                        message: "Failed to paste media"
                    )
                }
            }
        }
    }

    func deleteMediaFromMirrors(item: MediaItem) {
        let sha256 = extractViewerSHA256(from: item.url)
        guard !sha256.isEmpty else { return }
        Task {
            await MediaBackupActions.deleteFromMirrors(hash: sha256, configService: configService, nostrService: nostrService)
        }
    }

    func deleteMediaEverywhere(item: MediaItem) {
        let sha256 = extractViewerSHA256(from: item.url)
        guard !sha256.isEmpty else { return }
        Task {
            let localOk = await MediaBackupActions.deleteEverywhere(hash: sha256, configService: configService, nostrService: nostrService)
            // Only drop the tile once the device copy is really gone.
            guard localOk else { return }
            // Instantly clean up local state
            self.blossomCache.items.removeAll(where: { normalizedKeyStatic(for: $0.url) == sha256 })
            self.displayMedia.removeAll(where: { normalizedKeyStatic(for: $0.url) == sha256 })

            if selectedMedia?.url == item.url {
                withAnimation(Motion.fade) {
                    selectedMedia = nil
                    dragOffset = .zero
                }
            }

            scheduleUpdateDisplayData()
        }
    }

    func extractViewerSHA256(from url: URL) -> String {
        return normalizedKeyStatic(for: url)
    }
}
