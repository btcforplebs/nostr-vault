import Foundation
import CryptoKit
import os.log

/// BUD-02 Blob Descriptor returned by Blossom servers on successful upload
public struct BlobDescriptor: Codable {
    public let url: String
    public let sha256: String?
    public let size: Int?
    public let type: String?
    public let uploaded: Int?

    public init(url: String, sha256: String?, size: Int?, type: String?, uploaded: Int?) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.type = type
        self.uploaded = uploaded
    }
}

/// Source for a Blossom upload — either in-memory data or an on-disk file.
/// File uploads stream from disk, avoiding loading large videos into memory.
enum UploadSource {
    case data(Data)
    case file(URL)

    var byteCount: Int {
        switch self {
        case .data(let d):
            return d.count
        case .file(let url):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int) ?? 0
        }
    }
}

/// Handles uploading media to local and external Blossom servers
class BlossomService: @unchecked Sendable {
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
    func uploadAndMirror(data: Data, sha256: String, contentType: String = "application/octet-stream", progress: ((Double) -> Void)? = nil) async -> URL? {
        return await uploadAndMirror(source: .data(data), sha256: sha256, contentType: contentType, progress: progress)
    }

    /// File-based variant that streams the upload from disk — use for large
    /// videos so the file doesn't sit fully in memory during upload.
    func uploadAndMirror(fileURL: URL, sha256: String, contentType: String = "application/octet-stream", progress: ((Double) -> Void)? = nil) async -> URL? {
        return await uploadAndMirror(source: .file(fileURL), sha256: sha256, contentType: contentType, progress: progress)
    }

    /// Save media to the local relay and attempt to push to configured external mirrors.
    /// Unlike uploadAndMirror, success is determined by the LOCAL relay upload only —
    /// external mirrors are attempted as a best-effort side effect but do not affect the result.
    /// Use this for "save to my relay" actions (viewer mirror button) rather than compose uploads
    /// where you need an accessible external URL to embed in a note.
    /// - Returns: true if the local relay accepted the upload, false otherwise.
    func saveToLocalRelay(data: Data, sha256: String, contentType: String = "application/octet-stream") async -> Bool {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        let localURLStr = "http://127.0.0.1:\(port)"
        #else
        let localURLStr = "https://localhost:\(port)"
        #endif

        let localResult = await uploadToServer(source: .data(data), url: localURLStr, sha256: sha256, contentType: contentType, useLocalhostSession: true)
        guard localResult != nil else {
            logger.error("saveToLocalRelay: local upload failed at \(localURLStr)")
            return false
        }
        logger.info("saveToLocalRelay: local upload succeeded (\(data.count) bytes)")

        // Fire-and-forget: push to external mirrors without blocking the result.
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        if !mirrors.isEmpty {
            Task {
                await withTaskGroup(of: Void.self) { group in
                    for mirror in mirrors {
                        group.addTask {
                            let parsed = URL(string: mirror)
                            let useLocal = parsed.map { self.isLocalhost($0) } ?? false

                            // BUD-06: Preflight check — skip mirror if server rejects
                            let accepted = await self.preflightCheck(
                                url: mirror, sha256: sha256,
                                contentLength: data.count, contentType: contentType,
                                useLocalhostSession: useLocal
                            )
                            guard accepted else {
                                self.logger.info("saveToLocalRelay: skipping \(mirror) — BUD-06 preflight rejected")
                                return
                            }

                            let result = await self.uploadToServer(source: .data(data), url: mirror, sha256: sha256, contentType: contentType, useLocalhostSession: useLocal)
                            if result != nil {
                                self.logger.info("saveToLocalRelay: also mirrored to \(mirror)")
                            } else {
                                self.logger.warning("saveToLocalRelay: mirror to \(mirror) failed (non-blocking)")
                            }
                        }
                    }
                }
            }
        }

        return true
    }

    private func uploadAndMirror(source: UploadSource, sha256: String, contentType: String, progress: ((Double) -> Void)?) async -> URL? {
        let port = await MainActor.run { configService.config.relayPort }

        #if os(macOS)
        let localURLStr = "http://127.0.0.1:\(port)"
        #else
        let localURLStr = "https://localhost:\(port)"
        #endif

        // Step 1: Upload to local Blossom first (skip detailed progress since it is local and instant)
        let localSuccess = await uploadToServer(source: source, url: localURLStr, sha256: sha256, contentType: contentType, useLocalhostSession: true)
        guard localSuccess != nil else {
            logger.error("Failed to upload to local Blossom at \(localURLStr)")
            return nil
        }

        // Step 2: Get mirrors on main actor
        let mirrors = await MainActor.run {
            configService.config.activeBlossomMirrors
        }

        logger.info("Found \(mirrors.count) configured Blossom mirrors: \(mirrors)")

        // Step 3: Upload to external mirrors concurrently
        var mirrorURLs: [URL] = []

        if !mirrors.isEmpty {
            logger.debug("Attempting to mirror to: \(mirrors.description)")
            let results = await withTaskGroup(of: (String, URL?).self) { group in
                for (index, mirrorURL) in mirrors.enumerated() {
                    logger.debug("Processing mirror: '\(mirrorURL)' (length: \(mirrorURL.count))")
                    group.addTask {
                        // Only report progress for the first remote mirror to avoid progress jitter
                        let progressHandler = (index == 0) ? progress : nil
                        let parsed = URL(string: mirrorURL)
                        let useLocalSession = parsed.map { self.isLocalhost($0) } ?? false

                        // BUD-06: Preflight check — skip mirror if server rejects
                        let accepted = await self.preflightCheck(
                            url: mirrorURL, sha256: sha256,
                            contentLength: source.byteCount, contentType: contentType,
                            useLocalhostSession: useLocalSession
                        )
                        guard accepted else {
                            self.logger.info("BUD-06: Skipping mirror \(mirrorURL) — preflight rejected")
                            return (mirrorURL, nil)
                        }

                        let result = await self.uploadToServer(source: source, url: mirrorURL, sha256: sha256, contentType: contentType, useLocalhostSession: useLocalSession, progress: progressHandler)
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
    private func uploadToServer(source: UploadSource, url: String, sha256: String, contentType: String, useLocalhostSession: Bool, progress: ((Double) -> Void)? = nil) async -> URL? {
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

            logger.debug("Uploading to \(uploadURL.absoluteString), Blossom auth event kind 24242, data size: \(source.byteCount) bytes")

            do {
                // Use the appropriate URLSession
                let session = useLocalhostSession ? localhostSession : remoteSession
                let delegate = progress.map { UploadProgressDelegate(progressHandler: $0) }
                let (responseData, response): (Data, URLResponse)
                switch source {
                case .data(let bytes):
                    (responseData, response) = try await session.upload(for: request, from: bytes, delegate: delegate)
                case .file(let fileURL):
                    (responseData, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
                }

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

    // MARK: - BUD-06: Upload Preflight

    /// BUD-06: Pre-flight check via HEAD /upload before attempting a PUT upload.
    /// Returns true if the server would accept the upload, false if the mirror should be skipped.
    /// Fail-open: returns true on network errors or if the server doesn't support BUD-06.
    private func preflightCheck(url: String, sha256: String, contentLength: Int, contentType: String, useLocalhostSession: Bool) async -> Bool {
        guard var serverURL = URL(string: url) else { return true }

        let isLocalNetwork = isLocalhost(serverURL)
        if serverURL.scheme == "http" && !isLocalNetwork {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secureURL = components?.url { serverURL = secureURL }
        }

        let uploadURL = serverURL.appendingPathComponent("upload")

        // Kind 24242 auth — same as uploadToServer
        let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600
        let authTags = [
            ["t", "upload"],
            ["x", sha256],
            ["expiration", String(expirationTimestamp)]
        ]
        let authContent = "Preflight \(sha256.prefix(8))..."

        guard let authEvent = await MainActor.run(body: {
            nostrService.signEvent(kind: 24242, content: authContent, tags: authTags)
        }) else {
            logger.warning("BUD-06: Failed to sign preflight auth for \(url)")
            return true // Fail-open
        }

        guard let authJSON = try? JSONEncoder().encode(authEvent) else { return true }
        let authBase64 = authJSON.base64EncodedString()

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "HEAD"
        request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")
        request.setValue(sha256, forHTTPHeaderField: "X-SHA-256")
        request.setValue(String(contentLength), forHTTPHeaderField: "X-Content-Length")
        request.setValue(contentType, forHTTPHeaderField: "X-Content-Type")
        request.timeoutInterval = 15

        do {
            let session = useLocalhostSession ? localhostSession : remoteSession
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.debug("BUD-06: Preflight OK for \(url)")
                    return true
                }
                let reason = httpResponse.value(forHTTPHeaderField: "X-Reason") ?? "none"
                logger.info("BUD-06: Preflight rejected by \(url) — status \(httpResponse.statusCode), reason: \(reason)")
                return false
            }
        } catch {
            logger.warning("BUD-06: Preflight network error for \(url): \(error.localizedDescription)")
        }
        return true // Fail-open
    }

    // MARK: - Download & Mirror from External Servers

    /// Download media from any URL and store it in the local Blossom server.
    /// Computes SHA256 from the downloaded data — works with any remote server, not just configured mirrors.
    /// - Parameter url: The full URL to download from (e.g., https://blossom.primal.net/abc123.jpg)
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromURL(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

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

            // Save directly to the local file system (no HTTP upload needed!)
            let relayDataDir = await MainActor.run { configService.relayDataDir }
            let blossomDir = relayDataDir.appendingPathComponent(await MainActor.run { configService.config.blossomPath })
            
            try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
            
            let fileURL = blossomDir.appendingPathComponent(sha256)
            try data.write(to: fileURL)
            
            logger.info("Successfully downloaded \(sha256.prefix(8)) from \(url.host ?? "remote") directly to local file system")
            
            // Mirror to external servers concurrently
            let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
            if !mirrors.isEmpty {
                logger.info("Mirroring downloaded blob \(sha256.prefix(8)) to \(mirrors.count) external mirrors")
                await withTaskGroup(of: Void.self) { group in
                    for mirrorURL in mirrors {
                        group.addTask {
                            let parsed = URL(string: mirrorURL)
                            let useLocalSession = parsed.map { self.isLocalhost($0) } ?? false
                            _ = await self.uploadToServer(source: .data(data), url: mirrorURL, sha256: sha256, contentType: httpResponse.mimeType ?? "application/octet-stream", useLocalhostSession: useLocalSession)
                        }
                    }
                }
            }
            
            return true
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

                // Save directly to the local file system (no HTTP upload needed!)
                let relayDataDir = await MainActor.run { configService.relayDataDir }
                let blossomDir = relayDataDir.appendingPathComponent(await MainActor.run { configService.config.blossomPath })
                
                try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
                
                let fileURL = blossomDir.appendingPathComponent(sha256)
                try data.write(to: fileURL)

                logger.info("Successfully mirrored \(sha256.prefix(8)) from \(mirror) directly to local file system")
                return true
            } catch {
                logger.warning("Download from \(mirror)/\(sha256.prefix(8)) error: \(error.localizedDescription)")
                continue
            }
        }

        logger.error("Failed to download \(sha256.prefix(8)) from any mirror")
        return false
    }

    /// Mirror all owner media from external Blossom servers to local storage
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorAllFromExternal(progress: ((Int, Int) -> Void)? = nil) async -> Int {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let ownerPubkey = await MainActor.run { nostrService.ownerHexPubkey }
        let whitelistedPubkeys = await MainActor.run { configService.whitelistedHexPubkeys }
        let allPubkeys = ([ownerPubkey] + Array(whitelistedPubkeys)).filter { !$0.isEmpty }

        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured")
            return 0
        }

        // Get local blob hashes
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
        let localHashes: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(atPath: blossomDir.path) {
            localHashes = Set(files.filter { !$0.starts(with: ".") && $0 != "LOCK" })
        } else {
            localHashes = []
        }

        // Discover blobs from mirrors using BUD-02 /list endpoint with cursor pagination
        // Queries each pubkey (owner + whitelisted) on each mirror
        var remoteBlobHashes: Set<String> = []
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else { continue }

            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url { mirrorURL = secureURL }
            }

            for pubkey in allPubkeys {
                let baseListURL = mirrorURL.appendingPathComponent("list").appendingPathComponent(pubkey)
                var cursor: String? = nil
                var totalForPubkey = 0

                // Paginate through all results (BUD-02: cursor = sha256 of last blob, limit = page size)
                while true {
                    var components = URLComponents(url: baseListURL, resolvingAgainstBaseURL: false)
                    var queryItems: [URLQueryItem] = []
                    if let cursor = cursor {
                        queryItems.append(URLQueryItem(name: "cursor", value: cursor))
                    }
                    if !queryItems.isEmpty {
                        components?.queryItems = queryItems
                    }

                    guard let pageURL = components?.url else { break }
                    var request = URLRequest(url: pageURL)
                    request.timeoutInterval = 30

                    do {
                        let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                        let (data, response) = try await session.data(for: request)
                        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { break }

                        guard let descriptors = try? JSONDecoder().decode([BlobDescriptor].self, from: data),
                              !descriptors.isEmpty else { break }

                        for desc in descriptors {
                            if let hash = desc.sha256 {
                                remoteBlobHashes.insert(hash)
                            }
                        }
                        totalForPubkey += descriptors.count

                        // Use last sha256 as cursor for next page
                        // If we got fewer results than a full page, this is the last page
                        guard let lastHash = descriptors.last?.sha256 else { break }
                        if descriptors.count < 250 {
                            break
                        }
                        cursor = lastHash
                    } catch {
                        logger.warning("Failed to list blobs from \(mirror) for \(pubkey.prefix(8)): \(error.localizedDescription)")
                        break
                    }
                }

                if totalForPubkey > 0 {
                    let label = pubkey == ownerPubkey ? "owner" : "whitelisted \(pubkey.prefix(8))"
                    logger.info("Found \(totalForPubkey) blobs on \(mirror) for \(label)")
                }
            }
        }

        // Find blobs that exist remotely but not locally
        let missingHashes = remoteBlobHashes.subtracting(localHashes)
        guard !missingHashes.isEmpty else {
            logger.info("All remote blobs already mirrored locally")
            return 0
        }

        logger.info("Found \(missingHashes.count) blobs to mirror from external servers")
        let sortedHashes = Array(missingHashes).sorted()
        var mirrored = 0
        var completedCount = 0
        let total = sortedHashes.count

        await withTaskGroup(of: Bool.self) { group in
            var queued = 0
            for hash in sortedHashes {
                if queued >= 4 {
                    if let success = await group.next() {
                        completedCount += 1
                        if success { mirrored += 1 }
                        progress?(completedCount, total)
                    }
                }
                group.addTask {
                    await self.downloadFromMirrors(sha256: hash)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success { mirrored += 1 }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) blobs from external servers")
        return mirrored
    }

    /// Mirror media from note events (kind 1063 file metadata) that aren't already stored locally.
    /// Unlike mirrorAllFromExternal (which only checks configured mirrors via BUD-04), this scans
    /// the actual media URLs from synced notes — handling media on any server (e.g., Primal's blossom).
    /// - Parameter noteMedia: The array of MediaItem from nostrService.noteMedia
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorFromNoteMedia(_ noteMedia: [MediaItem], progress: ((Int, Int) -> Void)? = nil) async -> Int {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let ownerPubkey = await MainActor.run { nostrService.ownerHexPubkey }
        let whitelistedPubkeys = await MainActor.run { configService.whitelistedHexPubkeys }

        // Get local blob hashes
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
        let localHashes: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(atPath: blossomDir.path) {
            localHashes = Set(files.filter { !$0.starts(with: ".") && $0 != "LOCK" })
        } else {
            localHashes = []
        }

        // Find remote media URLs from owner or whitelisted accounts that aren't stored locally
        var urlsToMirror: [URL] = []
        for item in noteMedia {
            guard let pubkey = item.pubkey,
                  pubkey == ownerPubkey ||
                  whitelistedPubkeys.contains(pubkey) else { continue }
            // Skip local URLs
            let host = item.url.host?.lowercased() ?? ""
            if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" { continue }

            // Extract hash from URL to check if already local
            let lastComponent = item.url.deletingPathExtension().lastPathComponent
            if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
                if localHashes.contains(lastComponent) { continue }
            }

            urlsToMirror.append(item.url)
        }

        guard !urlsToMirror.isEmpty else {
            logger.info("No missing media found in note events")
            return 0
        }

        logger.info("Found \(urlsToMirror.count) media items from notes to mirror locally")
        var mirrored = 0
        var completedCount = 0
        let total = urlsToMirror.count

        // Process concurrently with a limit of 4 simultaneous downloads
        await withTaskGroup(of: Bool.self) { group in
            var queued = 0
            for url in urlsToMirror {
                if queued >= 4 {
                    if let success = await group.next() {
                        completedCount += 1
                        if success { mirrored += 1 }
                        progress?(completedCount, total)
                    }
                }
                group.addTask {
                    await self.downloadFromURL(url: url)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success { mirrored += 1 }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) media from note events")
        return mirrored
    }

    /// Returns the local Blossom server URL string
    private func localBlossomURL() async -> String {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        return "http://127.0.0.1:\(port)"
        #else
        return "https://localhost:\(port)"
        #endif
    }

    /// Delete media from mirrors only
    /// - Parameter sha256: The SHA256 hash of the media to delete
    /// - Returns: true if deletion succeeded on at least one mirror, false if all failed
    func deleteFromMirrors(sha256: String) async -> Bool {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured for deletion")
            return false
        }

        var successCount = 0
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

            let deleteURL = mirrorURL.appendingPathComponent(sha256)
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 30

            // Create Blossom auth event for deletion per BUD-02 spec
            let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600
            let authTags = [
                ["t", "delete"],
                ["x", sha256],
                ["u", deleteURL.absoluteString],
                ["expiration", String(expirationTimestamp)]
            ]

            let authContent = "Delete blob \(sha256.prefix(8))..."

            let authEvent = await MainActor.run {
                nostrService.signEvent(kind: 24242, content: authContent, tags: authTags)
            }

            guard let authEvent = authEvent else {
                logger.error("Failed to create Blossom auth event for deletion from \(mirror)")
                continue
            }

            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event for deletion from \(mirror)")
                continue
            }

            let authBase64 = authJSON.base64EncodedString()
            request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")

            do {
                let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                let (data, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    if (200...204).contains(httpResponse.statusCode) {
                        logger.info("Successfully deleted \(sha256.prefix(8)) from mirror \(mirror)")
                        successCount += 1
                    } else if httpResponse.statusCode == 404 {
                        logger.info("Confirmed \(sha256.prefix(8)) is already absent from mirror \(mirror)")
                        successCount += 1
                    } else {
                        let bodyString = String(data: data, encoding: .utf8) ?? "(binary/empty)"
                        logger.warning("Failed to delete from \(mirror) with status \(httpResponse.statusCode), response: \(bodyString)")
                    }
                }
            } catch {
                logger.error("Error deleting from \(mirror): \(error.localizedDescription)")
            }
        }

        return successCount > 0
    }

    /// Delete media from local Blossom storage
    /// - Parameter sha256: The SHA256 hash of the media to delete
    /// - Returns: true if deletion succeeded, false otherwise
    func deleteFromLocal(sha256: String) async -> Bool {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        // Try to delete the exact hash
        let fileURL = blossomDir.appendingPathComponent(sha256)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                logger.info("Successfully deleted \(sha256.prefix(8)) from local storage")
                return true
            } catch {
                logger.error("Failed to delete from local storage: \(error.localizedDescription)")
                return false
            }
        }

        // Try to find file with hash + extension (e.g., sha256.jpg)
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: blossomDir.path)
            for filename in contents {
                if filename.hasPrefix(sha256) && filename.count > 64 {
                    let extensionedURL = blossomDir.appendingPathComponent(filename)
                    try FileManager.default.removeItem(at: extensionedURL)
                    logger.info("Successfully deleted \(filename) from local storage")
                    return true
                }
            }
        } catch {
            logger.error("Failed to search local directory: \(error.localizedDescription)")
            return false
        }

        logger.warning("Media file not found in local storage: \(sha256.prefix(8))")
        return false
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

/// Helper class conforming to NSObject and URLSessionTaskDelegate to report body upload progress.
class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progressHandler: (Double) -> Void
    
    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler(progress)
    }
}

