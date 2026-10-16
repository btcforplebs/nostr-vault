import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Where a post's attachment ended up. Three different situations with
    /// three different remedies — they used to share one nil and one message
    /// ("check your connection"), which sent us looking at the network when
    /// the blob was sitting safely in the phone's own relay.
    enum PostUploadOutcome {
        /// An outside server accepted it; this URL goes in the note.
        case hosted(URL)
        /// In this device's relay, but no outside server took it. The post can
        /// wait for one (`MediaPostQueue`). `unreachable` is what was tried.
        case savedOnDevice(unreachable: [String])
        /// In this device's relay, and there is no outside server to try.
        case noOutsideServer
        /// Never reached this device's relay.
        case notSavedOnDevice
    }

    /// Upload a post attachment: this device's relay first, then the outside
    /// Blossom servers. `skipOutsideServers` saves locally only — used once an
    /// earlier attachment of the same post found every outside server down,
    /// so the rest don't each wait out the same retry.
    func uploadForPost(data: Data, sha256: String, contentType: String = "application/octet-stream", skipOutsideServers: Bool = false, progress: ((Double) -> Void)? = nil) async -> PostUploadOutcome {
        return await uploadAndMirror(source: .data(data), sha256: sha256, contentType: contentType, skipOutsideServers: skipOutsideServers, progress: progress)
    }

    /// File-based variant that streams the upload from disk — use for large
    /// videos so the file doesn't sit fully in memory during upload.
    func uploadForPost(fileURL: URL, sha256: String, contentType: String = "application/octet-stream", skipOutsideServers: Bool = false, progress: ((Double) -> Void)? = nil) async -> PostUploadOutcome {
        return await uploadAndMirror(source: .file(fileURL), sha256: sha256, contentType: contentType, skipOutsideServers: skipOutsideServers, progress: progress)
    }

    /// Send a blob that is already in this device's relay to the outside
    /// servers, returning the URL of the first that accepts it. What
    /// `MediaPostQueue` calls when it retries a waiting post. One pass only —
    /// the queue itself is the retry.
    func hostLocalBlob(sha256: String, contentType: String) async -> URL? {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else { return nil }
        guard await RelayProcessManager.shared.ensureRelayReady() else {
            appLog("waiting post: this device's relay is not ready yet — will retry", level: "WARN")
            return nil
        }
        let localBase = await localBlossomURL()
        guard let localURL = URL(string: "\(localBase)/\(sha256)") else { return nil }

        // Stream through a temp file: a queued video can be hundreds of MB.
        let tempURL: URL
        do {
            let (downloaded, response) = try await localhostSession.download(from: localURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                appLog("waiting post: blob \(sha256.prefix(8)) not readable from this device's relay (HTTP \(code))", level: "ERROR")
                try? FileManager.default.removeItem(at: downloaded)
                return nil
            }
            tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("queued-\(sha256)")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: downloaded, to: tempURL)
        } catch {
            appLog("waiting post: could not read blob \(sha256.prefix(8)) from this device's relay: \(error.localizedDescription)", level: "ERROR")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let auth = await makeUploadAuth(sha256: sha256)
        if let url = await firstHostingMirror(source: .file(tempURL), sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: nil) {
            appLog("waiting post: \(sha256.prefix(8)) now hosted at \(url.absoluteString)")
            return url
        }
        appLog("waiting post: no outside server accepted \(sha256.prefix(8)) yet (\(mirrors))", level: "WARN")
        return nil
    }

    /// Save media to the local relay and attempt to push to configured external mirrors.
    /// Unlike uploadAndMirror, success is determined by the LOCAL relay upload only —
    /// external mirrors are attempted as a best-effort side effect but do not affect the result.
    /// Use this for "save to my relay" actions (viewer mirror button) rather than compose uploads
    /// where you need an accessible external URL to embed in a note.
    /// - Returns: true if the local relay accepted the upload, false otherwise.
    func saveToLocalRelay(data: Data, sha256: String, contentType: String = "application/octet-stream", mirrorToExternal: Bool = true) async -> Bool {
        return await saveToLocalRelay(source: .data(data), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal)
    }

    /// File-based variant that streams the upload from disk — use for large videos
    /// so the entire file doesn't sit in memory during upload.
    func saveToLocalRelay(fileURL: URL, sha256: String, contentType: String = "application/octet-stream", mirrorToExternal: Bool = true, progress: ((Double) -> Void)? = nil) async -> Bool {
        return await saveToLocalRelay(source: .file(fileURL), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal, progress: progress)
    }
}
