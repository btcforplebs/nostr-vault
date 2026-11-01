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
        // left; ask for the time to finish it, and give it back when that
        // runs out rather than have the app killed for overstaying.
        let backgroundTime = BackgroundUploadTime(name: "ComposeUpload")
        defer { backgroundTime.end() }
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
        // The upload is signed by whichever account is active (makeUploadAuth).
        let signerAtStart = nostrService.activeHexPubkey
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
        // Asked before the upload: was this blob new to every server a delete
        // would reach? Only then may removing it delete it (UploadDeleteRule).
        var freshServers: [String]?
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
            freshServers = await blossomService.serversLackingBlob(sha256: hash)
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
            freshServers = await blossomService.serversLackingBlob(sha256: hash)
            pixelSize = ComposeView.pixelSize(ofImageData: data)
            byteCount = data.count
            outcome = await blossomService.uploadForPost(data: data, sha256: hash, contentType: mimeType,
                                                         skipOutsideServers: skipOutside, progress: progress)
        } else {
            outcome = .notSavedOnDevice
        }

        let signer = UploadSigner.recorded(atStart: signerAtStart, atEnd: nostrService.activeHexPubkey)
        if case .hosted = outcome, let sha256, let freshServers, note.freshUploads[sha256] == nil {
            note.freshUploads[sha256] = .init(servers: freshServers, signer: signer)
        }
        // Taken out while it was going up: nothing to record, and take back
        // what landed on an outside server anyway.
        guard !Task.isCancelled, note.attachments.contains(where: { $0.id == id }) else {
            if case .hosted = outcome, let sha256 { deleteIfUnused(sha256: sha256) }
            return
        }
        note.update(id) {
            $0.sha256 = sha256
            $0.pixelSize = pixelSize
            $0.byteCount = byteCount
            $0.signer = signer
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

    /// Before Post: one more try for each attachment that did not upload, a
    /// fresh upload for each one another account signed, and one more pass at
    /// the outside servers for each saved only on this device (the server
    /// that was asleep at pick time may be up by now).
    /// Returns the first failure's message, or nil when nothing failed.
    @MainActor
    func finishUploadsForPost(lockedHex: String) async -> String? {
        for attachment in note.attachments {
            if case .failed = attachment.upload { startUpload(for: attachment.id) }
        }
        await awaitUploads()
        // Picked as one account, posted as another: that account's link must
        // not go out in this one's note (UploadSigner). Upload it again as
        // this account, at the same place in the text.
        for attachment in note.attachments
        where attachment.upload.isFinished && UploadSigner.needsReupload(signer: attachment.signer, lockedHex: lockedHex) {
            note.unplace(attachment.id)
            note.update(attachment.id) {
                $0.url = nil
                $0.isUploaded = false
                $0.signer = nil
            }
            startUpload(for: attachment.id)
        }
        await awaitUploads()
        for attachment in note.attachments where attachment.upload == .savedOnDevice {
            guard let sha256 = attachment.sha256 else { continue }
            let mime = attachment.type.preferredMIMEType ?? "application/octet-stream"
            let signerAtStart = nostrService.activeHexPubkey
            if let url = await blossomService.hostLocalBlob(sha256: sha256, contentType: mime) {
                let signer = UploadSigner.recorded(atStart: signerAtStart, atEnd: nostrService.activeHexPubkey)
                note.update(attachment.id) { $0.signer = signer }
                land(attachment.id, at: url)
            }
        }
        for attachment in note.attachments {
            if case .failed(let message) = attachment.upload { return message }
        }
        return nil
    }

    /// Takes an attachment out of the note. One this composer put on an
    /// outside server is deleted there too (`deleteIfUnused`): before uploads
    /// started at pick, nothing left the device until Post.
    @MainActor
    func withdraw(_ id: UUID) {
        let attachment = note.attachments.first(where: { $0.id == id })
        note.remove(id)
        if let attachment, attachment.upload == .hosted, let sha256 = attachment.sha256 {
            deleteIfUnused(sha256: sha256)
        }
    }

    /// The note is being thrown away: delete every photo it put on an outside server.
    @MainActor
    func withdrawHostedUploads() {
        for attachment in note.attachments {
            withdraw(attachment.id)
        }
    }

    /// Deletes a blob this composer put up, when `UploadDeleteRule` allows
    /// it: no server had it before (so no other note shows it), no photo
    /// left in this note has the same hash, Post was never tapped, and the
    /// account that uploaded it is the active one. Only the servers asked
    /// before the upload are sent the delete; this device's vault keeps its copy.
    @MainActor
    private func deleteIfUnused(sha256: String) {
        guard let servers = UploadDeleteRule.deleteTargets(
            sha256: sha256, fresh: note.freshUploads[sha256],
            otherHashes: note.attachments.map(\.sha256),
            postTapped: note.postTapped, activeHex: nostrService.activeHexPubkey) else { return }
        note.freshUploads[sha256] = nil
        let service = blossomService
        Task.detached(priority: .utility) {
            let report = await service.deleteFromMirrorsReport(sha256: sha256, photoURL: nil,
                                                               includeHomeVault: false, onlyServers: servers)
            if !report.failed.isEmpty {
                print("ComposeView: removed photo \(sha256.prefix(8)) still on \(report.failedHosts.joined(separator: ", "))")
            }
        }
    }
}

#if os(iOS)
/// Background time for one upload, handed back when iOS says it has run
/// out (the expiration handler) or when the upload ends, whichever is first.
@MainActor
final class BackgroundUploadTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
