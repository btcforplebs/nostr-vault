import Foundation
import CryptoKit
import os.log

/// BUD-02 Blob Descriptor returned by Blossom servers on successful upload
private struct BlobDescriptor: Codable {
    let url: String
    let sha256: String?
    let size: Int?
    let type: String?
    let uploaded: Int?
}

/// Handles uploading media to local and external Blossom servers
class BlossomService {
    let configService: ConfigService
    let nostrService: NostrService
    private let logger = Logger(subsystem: "com.bitvora.haven", category: "blossom")
    private let localhostDelegate: LocalhostTrustDelegate
    private let localhostSession: URLSession
    private let remoteSession: URLSession

    init(configService: ConfigService, nostrService: NostrService) {
        self.configService = configService
        self.nostrService = nostrService

        // Create a session that trusts self-signed certs for localhost
        // Store delegate as property to ensure it stays alive for the lifetime of the session
        let localhostConfig = URLSessionConfiguration.default
        localhostConfig.timeoutIntervalForRequest = 600  // 10 minutes
        localhostConfig.timeoutIntervalForResource = 900  // 15 minutes
        self.localhostDelegate = LocalhostTrustDelegate()
        self.localhostSession = URLSession(configuration: localhostConfig, delegate: localhostDelegate, delegateQueue: nil)

        // Create a session for remote mirrors with proper timeout configuration
        let remoteConfig = URLSessionConfiguration.default
        remoteConfig.timeoutIntervalForRequest = 600  // 10 minutes
        remoteConfig.timeoutIntervalForResource = 900  // 15 minutes
        remoteConfig.waitsForConnectivity = true  // Wait for network availability
        self.remoteSession = URLSession(configuration: remoteConfig, delegate: nil, delegateQueue: nil)
    }

    /// Upload media to local Blossom and mirror to external servers
    /// - Parameters:
    ///   - data: The media file data
    ///   - sha256: The SHA256 hash of the data (hex string)
    /// - Returns: External mirror URL if at least one mirror succeeds, nil if all fail
    func uploadAndMirror(data: Data, sha256: String, contentType: String = "application/octet-stream") async -> URL? {
        let port = await MainActor.run { configService.config.relayPort }
        
        #if os(macOS)
        let localURLStr = "http://127.0.0.1:\(port)"
        #else
        let localURLStr = "https://localhost:\(port)"
        #endif

        // Step 1: Upload to local Blossom first
        let localSuccess = await uploadToServer(data: data, url: localURLStr, sha256: sha256, contentType: contentType, useLocalhostSession: true)
        guard localSuccess != nil else {
            logger.error("Failed to upload to local Blossom at \(localURLStr)")
            return nil
        }

        // Step 2: Get mirrors on main actor
        let mirrors = await MainActor.run {
            configService.config.blossomMirrors
        }

        logger.info("Found \(mirrors.count) configured Blossom mirrors: \(mirrors)")

        // Step 3: Upload to external mirrors concurrently
        var mirrorURLs: [URL] = []

        if !mirrors.isEmpty {
            logger.debug("Attempting to mirror to: \(mirrors.description)")
            let results = await withTaskGroup(of: (String, URL?).self) { group in
                for mirrorURL in mirrors {
                    logger.debug("Processing mirror: '\(mirrorURL)' (length: \(mirrorURL.count))")
                    group.addTask {
                        let result = await self.uploadToServer(data: data, url: mirrorURL, sha256: sha256, contentType: contentType, useLocalhostSession: false)
                        return (mirrorURL, result)
                    }
                }

                var successfulMirrors: [URL] = []
                for await (mirrorURL, result) in group {
                    if let url = result {
                        self.logger.info("✅ Mirror upload succeeded for \(mirrorURL): \(url.absoluteString)")
                        successfulMirrors.append(url)
                    } else {
                        self.logger.warning("❌ Mirror upload failed for \(mirrorURL)")
                    }
                }
                return successfulMirrors
            }

            mirrorURLs = results
        }

        // Return first successful external mirror
        if let externalURL = mirrorURLs.first {
            logger.info("✅ Using external Blossom mirror: \(externalURL.absoluteString)")
            return externalURL
        }

        // FAIL if no mirrors succeeded
        logger.error("❌ All Blossom mirror uploads failed — cannot post without accessible mirror URL")
        return nil
    }

    /// Upload media to a specific Blossom server with retry logic
    /// Uses Blossom HTTP Auth (kind 24242, per BUD-01 spec)
    private func uploadToServer(data: Data, url: String, sha256: String, contentType: String, useLocalhostSession: Bool) async -> URL? {
        let maxRetries = 3
        let parsedURL = URL(string: url)
        // isOnDeviceRelay: strict localhost only — used for response parsing (skip BlobDescriptor)
        let isOnDeviceRelay = parsedURL.map { host in
            guard let h = host.host?.lowercased() else { return false }
            return h == "localhost" || h == "127.0.0.1" || h == "0.0.0.0"
        } ?? false
        // isLocalNetwork: includes Tailscale/LAN — used for HTTPS skip (don't force https on LAN)
        let isLocalNetwork = parsedURL.map { isLocalhost($0) } ?? false

        for attempt in 0..<maxRetries {
            guard var serverURL = URL(string: url) else {
                logger.error("Invalid Blossom server URL: \(url)")
                return nil
            }

            // Ensure HTTPS for remote servers (skip for localhost and LAN/Tailscale)
            if serverURL.scheme == "http" && !isLocalNetwork {
                var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url {
                    serverURL = secureURL
                }
            }

            // BUD-02 standard: PUT /upload for all servers (local khatru/blossom + external)
            let uploadURL = serverURL.appendingPathComponent("upload")

            // Create Blossom auth event per BUD-02 spec (kind 24242)
            // Includes: t tag (operation type), x tag (sha256 hash), expiration tag
            let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600  // 1 hour expiration
            let authTags = [
                ["t", "upload"],                        // Operation type: upload
                ["x", sha256],                          // SHA256 hash of the blob being uploaded
                ["expiration", String(expirationTimestamp)]  // NIP-40 expiration
            ]

            let authContent = "Upload blob \(sha256.prefix(8))..."  // Human-readable content

            // Create auth event on main actor (kind 24242 per Blossom BUD-02 spec)
            let authEvent = await MainActor.run {
                nostrService.signEvent(kind: 24242, content: authContent, tags: authTags)
            }

            guard let authEvent = authEvent else {
                logger.error("Failed to create Blossom auth event for \(url)")
                return nil
            }

            // Encode auth event as JSON then base64 (Blossom spec)
            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event for \(url)")
                return nil
            }
            let authBase64 = authJSON.base64EncodedString()

            logger.debug("Auth event: kind=24242, tags=\(authTags.description)")
            logger.debug("Auth base64: \(authBase64.prefix(100))...")

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")  // Nostr auth scheme per Blossom spec
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 600  // 10 minutes for large file uploads to external mirrors

            logger.debug("Uploading to \(uploadURL.absoluteString), Blossom auth event kind 24242, data size: \(data.count) bytes")

            do {
                // Use the appropriate URLSession
                let session = useLocalhostSession ? localhostSession : remoteSession
                let (responseData, response) = try await session.upload(for: request, from: data)

                if let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) {
                    // For external/mirror servers, parse BUD-02 Blob Descriptor for the canonical URL
                    if !isOnDeviceRelay, let descriptor = try? JSONDecoder().decode(BlobDescriptor.self, from: responseData),
                       let downloadURL = URL(string: descriptor.url) {
                        logger.info("Successfully uploaded to \(url): \(descriptor.url)")
                        return downloadURL
                    }
                    // Fallback (local on-device relay or unparseable response): construct URL
                    let fileURL = serverURL.appendingPathComponent(sha256)
                    logger.info("Successfully uploaded to \(url): \(fileURL.absoluteString)")
                    return fileURL
                } else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let responseBody = String(data: responseData, encoding: .utf8) ?? "(binary)"
                    logger.warning("Upload to \(url) attempt \(attempt + 1)/\(maxRetries) failed with status: \(statusCode), response: \(responseBody)")

                    // Retry on transient errors (5xx)
                    if attempt < maxRetries - 1 && statusCode >= 500 {
                        let backoffNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: backoffNs)
                        continue
                    }
                    return nil
                }
            } catch {
                let errorDesc = error.localizedDescription
                logger.error("Upload to \(url) attempt \(attempt + 1)/\(maxRetries) caught error: \(errorDesc), error type: \(type(of: error))")

                if let urlError = error as? URLError {
                    logger.error("URLError code: \(urlError.code.rawValue)")
                }

                // Retry on network errors
                if attempt < maxRetries - 1 {
                    let backoffNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: backoffNs)
                    continue
                }
                return nil
            }
        }

        logger.error("Upload to \(url) failed after \(maxRetries) attempts")
        return nil
    }

    /// Check if a URL is localhost
    private func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" {
            return true
        }
        
        // Also consider local network IPs as local (e.g. Tailscale 100.x.x.x, 192.168.x.x, 10.x.x.x, .ts.net)
        if host.hasPrefix("100.") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.") || host.hasSuffix(".ts.net") {
            return true
        }
        
        return false
    }
}
