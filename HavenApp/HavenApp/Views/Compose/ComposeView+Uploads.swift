import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Uploads start the moment an attachment is picked, one at a time in the
/// order picked, while the author keeps writing. Each goes to this device's
/// relay first and then to the outside Blossom servers in the preferred
/// order (`BlossomService.uploadForPost`), with location data stripped
/// first (`MediaPrivacy`). Post waits only for the ones still going.
extension ComposeView {
    /// Queues the attachment's upload behind any already running.
    func startUpload(for id: UUID) {
        let previous = note.lastUpload
        note.update(id) { $0.upload = .waiting }
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await runUpload(id)
        }
        note.uploads[id] = task
        note.lastUpload = task
    }

    /// Waits for every upload still going; returns once each has finished.
    func awaitUploads() async {
        for task in Array(note.uploads.values) { await task.value }
    }

    @MainActor
    private func runUpload(_ id: UUID) async {
        guard let attachment = note.attachments.first(where: { $0.id == id }) else { return }
        #if os(iOS)
        // An upload started while writing can still be going when the app is
        // left; ask for the time to finish it.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "ComposeUpload", expirationHandler: nil)
        defer { UIApplication.shared.endBackgroundTask(bgTask) }
        #endif
        let mimeType = attachment.type.preferredMIMEType ?? "application/octet-stream"

        // Picked from the relay: already hosted, nothing to upload.
        if attachment.data == nil, attachment.fileURL == nil, let hostedURL = attachment.url {
            let blob = attachment.relayBlobFile
            var pixelSize: CGSize?
            if let blob {
                if attachment.isVideo {
                    pixelSize = await ComposeView.pixelSize(ofVideoAt: blob)
                } else if let data = try? Data(contentsOf: blob, options: .mappedIfSafe) {
                    pixelSize = ComposeView.pixelSize(ofImageData: data)
                }
            }
            note.update(id) {
                // Viewers on the mesh fetch by this hash from the photo node, whatever host the
                // link names: from the link, else the relay's own blob (named by its hash), else hashed.
                $0.sha256 = ComposeView.blossomHash(in: hostedURL)
                    ?? blob.flatMap { ComposeView.blossomHash(in: $0) ?? ComposeView.streamingSHA256(of: $0) }
                $0.pixelSize = pixelSize
                $0.byteCount = blob.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int }
                $0.upload = .hosted
            }
            note.place(hostedURL.absoluteString, for: id)
            return
        }

        note.update(id) { $0.upload = .uploading(progress: 0) }
        let progress: (Double) -> Void = { fraction in
            Task { @MainActor in
                note.update(id) { if case .uploading = $0.upload { $0.upload = .uploading(progress: fraction) } }
            }
        }
        let skipOutside = note.skipOutsideServers
        let outcome: BlossomService.PostUploadOutcome
        var sha256: String?
        var pixelSize: CGSize?
        var byteCount: Int?
        if let originalURL = attachment.fileURL {
            // Never upload where it was taken (MediaPrivacy).
            guard let fileURL = await MediaPrivacy.removingLocation(fromFileAt: originalURL) else {
                return fail(id, MediaPrivacy.failureMessage)
            }
            defer { if fileURL != originalURL { try? FileManager.default.removeItem(at: fileURL) } }
            guard let hash = ComposeView.streamingSHA256(of: fileURL) else {
                return fail(id, "Failed to read video file for upload.")
            }
            sha256 = hash
            pixelSize = await ComposeView.pixelSize(ofVideoAt: fileURL)
            byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int
            outcome = await blossomService.uploadForPost(fileURL: fileURL, sha256: hash, contentType: mimeType,
                                                         skipOutsideServers: skipOutside, progress: progress)
        } else if let originalData = attachment.data {
            // Never upload where it was taken (MediaPrivacy).
            guard let data = MediaPrivacy.removingLocation(fromImageData: originalData) else {
                return fail(id, MediaPrivacy.failureMessage)
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            sha256 = hash
            pixelSize = ComposeView.pixelSize(ofImageData: data)
            byteCount = data.count
            outcome = await blossomService.uploadForPost(data: data, sha256: hash, contentType: mimeType,
                                                         skipOutsideServers: skipOutside, progress: progress)
        } else {
            outcome = .notSavedOnDevice
        }

        // Taken out while it was going up: nothing to record.
        guard !Task.isCancelled, note.attachments.contains(where: { $0.id == id }) else { return }
        note.update(id) {
            $0.sha256 = sha256
            $0.pixelSize = pixelSize
            $0.byteCount = byteCount
        }
        switch outcome {
        case .hosted(let url):
            land(id, at: url)
        case .savedOnDevice(let unreachable):
            // Safe on this device; the post will wait for a server.
            note.skipOutsideServers = true
            note.unreachableServers = unreachable
            note.update(id) { $0.upload = .savedOnDevice }
        case .noOutsideServer:
            fail(id, MediaUploadOutcomeMessage.noOutsideServer)
        case .vaultDidNotTake:
            fail(id, MediaUploadOutcomeMessage.vaultDidNotTake)
        case .notSavedOnDevice:
            fail(id, MediaUploadOutcomeMessage.notSavedOnDevice)
        }
    }

    /// The attachment is on an outside server: record the link and write it
    /// in where the photo was picked.
    @MainActor
    func land(_ id: UUID, at url: URL) {
        note.update(id) {
            $0.url = url
            $0.isUploaded = true
            $0.upload = .hosted
        }
        note.place(url.absoluteString, for: id)
    }

    @MainActor
    private func fail(_ id: UUID, _ message: String) {
        note.update(id) { $0.upload = .failed(message: message) }
    }

    /// Before Post: one more try for each attachment that did not upload, and
    /// one more pass at the outside servers for each saved only on this
    /// device (the server that was asleep at pick time may be up by now).
    /// Returns the first failure's message, or nil when nothing failed.
    @MainActor
    func finishUploadsForPost() async -> String? {
        for attachment in note.attachments {
            if case .failed = attachment.upload { startUpload(for: attachment.id) }
        }
        await awaitUploads()
        for attachment in note.attachments where attachment.upload == .savedOnDevice {
            guard let sha256 = attachment.sha256 else { continue }
            let mime = attachment.type.preferredMIMEType ?? "application/octet-stream"
            if let url = await blossomService.hostLocalBlob(sha256: sha256, contentType: mime) {
                land(attachment.id, at: url)
            }
        }
        for attachment in note.attachments {
            if case .failed(let message) = attachment.upload { return message }
        }
        return nil
    }
}
