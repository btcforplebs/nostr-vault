import Foundation
import CryptoKit
import os.log

extension BlossomService {
    // MARK: - Download & Mirror from External Servers

    /// Download media from any URL and store it in the local Blossom server.
    /// Computes SHA256 from the downloaded data — works with any remote server, not just configured mirrors.
    /// - Parameters:
    ///   - url: The full URL to download from (e.g., https://blossom.primal.net/abc123.jpg)
    ///   - mirrorToExternal: Whether to also push the blob to configured external Blossom mirrors.
    ///     Pass `true` for user-initiated "Mirror to Blossom" actions so all configured servers receive the blob.
    ///     Defaults to `false` for internal/batch operations where only local storage is needed.
    ///   - date: The photo's own date (note created_at). Set as the stored file's
    ///     modified time so the Media grid doesn't move the copy to Today.
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromURL(url: URL, mirrorToExternal: Bool = false, date: Date? = nil) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120  // 2 minutes — 30s was too short for video files

        // Straight to a temp file, hashed as it arrives: a big video never
        // sits in memory whole (StreamingBlobDownload).
        switch await StreamingBlobDownload.fetch(request, configuration: remoteSession.configuration) {
        case .failure(let why):
            logger.warning("Download from \(url.absoluteString) skipped: \(why.reason)")
            return false
        case .success(let file):
            defer { try? FileManager.default.removeItem(at: file.url) }
            // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth), from the file.
            let success = await saveToLocalRelay(fileURL: file.url, sha256: file.sha256, contentType: file.contentType, mirrorToExternal: mirrorToExternal)
            if success {
                await stampCopiedIn(sha256: file.sha256, date: date)
                logger.info("Successfully mirrored \(file.sha256.prefix(8)) from \(url.host ?? "remote") (\(file.size) bytes)")
            }
            return success
        }
    }

    /// Download a blob from configured mirrors and store it in the local Blossom server
    /// - Parameter sha256: The SHA256 hash of the blob to download
    /// - Parameter date: The blob's real date (BUD-02 `uploaded`), set on the stored file.
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromMirrors(sha256: String, date: Date? = nil) async -> Bool {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured for download")
            return false
        }

        // Try each mirror until one succeeds
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else { continue }

            // Ensure HTTPS for remote servers
            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url {
                    mirrorURL = secureURL
                }
            }

            let blobURL = mirrorURL.appendingPathComponent(sha256)
            var request = URLRequest(url: blobURL)
            request.timeoutInterval = 30

            let local = isLocalhost(mirrorURL)
            let session = local ? localhostSession : remoteSession
            // Straight to a temp file, checked against sha256 as it arrives.
            let trustLocal: StreamingBlobDownload.Challenge = { challenge, done in
                LocalTLSTrust.handle(challenge, completionHandler: done)
            }
            let result: Result<StreamingBlobDownload.File, StreamingBlobDownload.Failure> = await StreamingBlobDownload.fetch(
                request, configuration: session.configuration, expectedSHA256: sha256,
                challenge: local ? trustLocal : nil)
            guard case .success(let file) = result else {
                if case .failure(let why) = result {
                    logger.warning("Download from \(mirror)/\(sha256.prefix(8)) skipped: \(why.reason)")
                    // No room here is no room from any mirror.
                    if case .noRoom = why { return false }
                }
                continue
            }
            defer { try? FileManager.default.removeItem(at: file.url) }

            // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth), from the file.
            // Skip external mirroring — the blob came FROM a configured mirror.
            let success = await saveToLocalRelay(fileURL: file.url, sha256: sha256, contentType: file.contentType, mirrorToExternal: false)
            if success {
                await stampCopiedIn(sha256: sha256, date: date)
                logger.info("Successfully mirrored \(sha256.prefix(8)) from \(mirror) (\(file.size) bytes)")
                return true
            } else {
                logger.warning("Local relay rejected upload of \(sha256.prefix(8)) from \(mirror)")
                continue
            }
        }

        logger.error("Failed to download \(sha256.prefix(8)) from any mirror")
        return false
    }

    /// Give a just-copied blob its real date on disk (see CopiedInDate).
    private func stampCopiedIn(sha256: String, date: Date?) async {
        guard let date else { return }
        let dir = await MainActor.run { configService.relayDataDir.appendingPathComponent(configService.config.blossomPath) }
        if !CopiedInDate.stamp(sha256: sha256, in: dir, date: date) {
            logger.info("Copied \(sha256.prefix(8)) kept its write time (no stored file or future date)")
        }
    }
}
