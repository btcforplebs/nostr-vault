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
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromURL(url: URL, mirrorToExternal: Bool = false) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120  // 2 minutes — 30s was too short for video files

        do {
            let (data, response) = try await remoteSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.warning("Download from \(url.absoluteString) failed with status \(status)")
                return false
            }

            // Compute SHA256 from downloaded data
            let hash = SHA256.hash(data: data)
            let sha256 = hash.compactMap { String(format: "%02x", $0) }.joined()
            let contentType = httpResponse.mimeType ?? "application/octet-stream"

            // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth).
            let success = await saveToLocalRelay(data: data, sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal)
            if success {
                logger.info("Successfully mirrored \(sha256.prefix(8)) from \(url.host ?? "remote") via local relay upload")
            }
            return success
        } catch {
            logger.warning("Download from \(url.absoluteString) error: \(error.localizedDescription)")
            return false
        }
    }

    /// Download a blob from configured mirrors and store it in the local Blossom server
    /// - Parameter sha256: The SHA256 hash of the blob to download
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromMirrors(sha256: String) async -> Bool {
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

            do {
                let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    logger.warning("Download from \(mirror)/\(sha256.prefix(8)) failed with status \(status)")
                    continue
                }

                // Verify SHA256
                let hash = SHA256.hash(data: data)
                let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
                guard computedHash == sha256 else {
                    logger.error("SHA256 mismatch downloading from \(mirror): expected \(sha256.prefix(16)), got \(computedHash.prefix(16))")
                    continue
                }

                let contentType = httpResponse.mimeType ?? "application/octet-stream"

                // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth).
                // Skip external mirroring — the blob came FROM a configured mirror.
                let success = await saveToLocalRelay(data: data, sha256: sha256, contentType: contentType, mirrorToExternal: false)
                if success {
                    logger.info("Successfully mirrored \(sha256.prefix(8)) from \(mirror) via local relay upload")
                    return true
                } else {
                    logger.warning("Local relay rejected upload of \(sha256.prefix(8)) from \(mirror)")
                    continue
                }
            } catch {
                logger.warning("Download from \(mirror)/\(sha256.prefix(8)) error: \(error.localizedDescription)")
                continue
            }
        }

        logger.error("Failed to download \(sha256.prefix(8)) from any mirror")
        return false
    }
}
