import Foundation
import CryptoKit

/// Handles uploading media to local and external Blossom servers
struct BlossomService {
    let configService: ConfigService
    let nostrService: NostrService

    /// Upload media to local Blossom and mirror to external servers
    /// - Parameters:
    ///   - data: The media file data
    ///   - sha256: The SHA256 hash of the data (hex string)
    /// - Returns: The URL to use in the post (external mirror if available, otherwise local)
    func uploadAndMirror(data: Data, sha256: String) async -> URL? {
        // Create auth event for Blossom (must be done on main actor)
        let authTags = [
            ["t", "upload"],
            ["x", sha256]
        ]

        let authEvent = await MainActor.run {
            nostrService.signEvent(kind: 24242, content: "Authorize Upload", tags: authTags)
        }

        guard authEvent != nil else {
            print("Failed to create auth event for Blossom upload")
            return nil
        }

        // Get mirrors and local URL on main actor
        let mirrors = await MainActor.run {
            configService.config.blossomMirrors
        }

        let localWebURL = await MainActor.run {
            configService.config.webURL
        }

        // Try to upload to external mirrors concurrently
        var mirrorURLs: [URL] = []

        if !mirrors.isEmpty {
            let results = await withTaskGroup(of: URL?.self) { group in
                for mirrorURL in mirrors {
                    group.addTask {
                        await self.uploadToServer(data: data, url: mirrorURL, authEvent: authEvent!, sha256: sha256)
                    }
                }

                var results: [URL] = []
                for await result in group {
                    if let url = result {
                        results.append(url)
                    }
                }
                return results
            }

            mirrorURLs = results
        }

        // Return first successful external mirror, or fall back to local
        if let externalURL = mirrorURLs.first {
            print("Using external Blossom mirror: \(externalURL.absoluteString)")
            return externalURL
        }

        // Fall back to local Blossom
        let localURL = URL(string: localWebURL)!
        return localURL.appendingPathComponent(sha256)
    }

    /// Upload media to a specific Blossom server
    private func uploadToServer(data: Data, url: String, authEvent: NostrEvent, sha256: String) async -> URL? {
        guard var serverURL = URL(string: url) else {
            print("Invalid Blossom server URL: \(url)")
            return nil
        }

        // Ensure HTTPS
        if serverURL.scheme == "http" && !isLocalhost(serverURL) {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secureURL = components?.url {
                serverURL = secureURL
            }
        }

        let uploadURL = serverURL.appendingPathComponent("upload")

        let authBase64 = try? JSONEncoder().encode(authEvent).base64EncodedString()

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(authBase64 ?? "")", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 30

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: data)

            if let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) {
                let fileURL = serverURL.appendingPathComponent(sha256)
                print("Successfully uploaded to \(url): \(fileURL.absoluteString)")
                return fileURL
            } else {
                print("Upload to \(url) failed with status code: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
        } catch {
            print("Upload to \(url) failed: \(error)")
            return nil
        }
    }

    /// Check if a URL is localhost
    private func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host == "localhost" || host == "127.0.0.1"
    }
}
