import Foundation
import CryptoKit
import os.log

extension BlossomService {
    // MARK: - Mirror Status Checking

    /// Check which configured mirrors have a specific blob
    /// - Parameter sha256: The SHA256 hash of the blob to check
    /// - Returns: Dictionary mapping mirror URL to availability status
    func checkMirrorStatus(sha256: String) async -> [String: Bool] {
        let presence = await checkMirrorPresence(sha256: sha256)
        return presence.mapValues { $0 == .present }
    }

    /// Asks every configured Blossom server whether it holds `sha256`.
    /// Unlike `checkMirrorStatus`, a server that could not be reached is
    /// reported as `.unreachable`, not as "does not have it".
    func checkMirrorPresence(sha256: String) async -> [String: BlobPresence] {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, BlobPresence).self) { group in
            for mirror in mirrors {
                group.addTask {
                    (mirror, await self.checkBlobExists(mirror: mirror, sha256: sha256))
                }
            }
            var results: [String: BlobPresence] = [:]
            for await (mirror, presence) in group {
                results[mirror] = presence
            }
            return results
        }
    }

    /// Whether one server holds `sha256`: the per-server check behind
    /// `checkMirrorPresence`, for testing a single server.
    func checkPresence(mirror: String, sha256: String) async -> BlobPresence {
        await checkBlobExists(mirror: mirror, sha256: sha256)
    }

    /// Check if a specific blob exists on a mirror server.
    /// A 2xx alone is not enough: some servers answer 200 with an HTML page
    /// for any path, which used to read as "Available" for every file.
    private func checkBlobExists(mirror: String, sha256: String) async -> BlobPresence {
        guard var mirrorURL = URL(string: mirror) else { return .unreachable }

        // Ensure HTTPS for remote servers
        if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
            var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secureURL = components?.url {
                mirrorURL = secureURL
            }
        }

        let blobURL = mirrorURL.appendingPathComponent(sha256)
        // Not HEAD: after a delete, blossom.band and blossom.nostr.build keep
        // answering HEAD with the old size, while a GET redirects to a
        // "404" placeholder image served as 200. A GET shows where the blob
        // really ends up; only its headers are read, never the body.
        var request = URLRequest(url: blobURL)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10

        do {
            let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.presence(statusCode: http.statusCode,
                                 contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                 contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                                 sha256: sha256,
                                 finalURL: http.url)
        } catch {
            logger.debug("checkBlobExists: \(mirror)/\(sha256.prefix(8)) error: \(error.localizedDescription)")
            return .unreachable
        }
    }

    /// The decision behind `checkBlobExists`, split out so it can be tested
    /// without a server.
    /// `finalURL` is where redirects ended. A blob's own location names its
    /// hash; a redirect that lands anywhere else is a placeholder.
    static func presence(statusCode: Int, contentType: String?, contentLength: String?,
                         sha256: String? = nil, finalURL: URL? = nil) -> BlobPresence {
        switch statusCode {
        case 200...299:
            if let type = contentType?.lowercased(), type.hasPrefix("text/html") { return .absent }
            if let sha256, let finalURL,
               !finalURL.absoluteString.lowercased().contains(sha256.lowercased()) { return .absent }
            if let length = contentLength.flatMap({ Int64($0) }), length == 0 { return .absent }
            return .present
        case 400...499:
            return .absent
        default:
            return .unreachable
        }
    }
}

/// Whether one Blossom server holds a blob.
enum BlobPresence: Sendable, Equatable {
    case present
    case absent
    /// The server did not answer (offline, timeout, 5xx), so we do not know.
    case unreachable
}
