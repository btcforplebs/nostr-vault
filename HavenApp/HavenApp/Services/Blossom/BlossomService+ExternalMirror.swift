import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Mirror all owner media from external Blossom servers to local storage
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorAllFromExternal(progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
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
        logMessage?("Local storage has \(localHashes.count) existing blob(s)", "INFO")

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

            logMessage?("Querying \(mirror) for blob list...", "INFO")

            // Create a BUD-02 auth event (kind 24242) for the list operation so servers
            // that require authentication return blob lists instead of empty/403.
            let listExpiration = Int64(Date().timeIntervalSince1970) + 3600
            let listAuthTags = [
                ["t", "list"],
                ["expiration", String(listExpiration)]
            ]
            let listAuthEvent = await nostrService.signEventAsync(kind: 24242, content: "List blobs", tags: listAuthTags)
            var listAuthHeader: String? = nil
            if let authEvent = listAuthEvent,
               let authJSON = try? JSONEncoder().encode(authEvent) {
                listAuthHeader = "Nostr \(authJSON.base64EncodedString())"
            }

            for pubkey in allPubkeys {
                let baseListURL = mirrorURL.appendingPathComponent("list").appendingPathComponent(pubkey)
                var totalForPubkey = 0

                var request = URLRequest(url: baseListURL)
                request.timeoutInterval = 30
                if let authHeader = listAuthHeader {
                    request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }

                do {
                    let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        logMessage?("List \(mirror)/list/\(pubkey.prefix(8))... returned HTTP \(code)", "WARN")
                        continue
                    }

                    guard let descriptors = try? JSONDecoder().decode([BlobDescriptor].self, from: data),
                          !descriptors.isEmpty else { continue }

                    for desc in descriptors {
                        if let hash = desc.sha256 {
                            remoteBlobHashes.insert(hash)
                        }
                    }
                    totalForPubkey = descriptors.count
                } catch {
                    logger.warning("Failed to list blobs from \(mirror) for \(pubkey.prefix(8)): \(error.localizedDescription)")
                    logMessage?("Failed to list blobs from \(mirror): \(error.localizedDescription)", "ERROR")
                }

                if totalForPubkey > 0 {
                    let label = pubkey == ownerPubkey ? "owner" : "whitelisted \(pubkey.prefix(8))"
                    logger.info("Found \(totalForPubkey) blobs on \(mirror) for \(label)")
                    logMessage?("Found \(totalForPubkey) blob(s) on \(mirror) for \(label)", "INFO")
                }
            }
        }

        // Find blobs that exist remotely but not locally
        let missingHashes = remoteBlobHashes.subtracting(localHashes)
        guard !missingHashes.isEmpty else {
            logger.info("All remote blobs already mirrored locally")
            logMessage?("All \(remoteBlobHashes.count) remote blob(s) already exist locally", "INFO")
            return 0
        }

        logger.info("Found \(missingHashes.count) blobs to mirror from external servers")
        logMessage?("\(missingHashes.count) blob(s) missing locally — downloading from mirrors...", "INFO")
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
                        if success {
                            mirrored += 1
                            logMessage?("Downloaded \(hash.prefix(12))... (\(completedCount)/\(total))", "INFO")
                        } else {
                            logMessage?("Failed to download \(hash.prefix(12))... (\(completedCount)/\(total))", "WARN")
                        }
                        progress?(completedCount, total)
                    }
                    // Throttle to avoid overwhelming the relay
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                group.addTask {
                    await self.downloadFromMirrors(sha256: hash)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success {
                    mirrored += 1
                    logMessage?("Downloaded \(sortedHashes[min(completedCount - 1, sortedHashes.count - 1)].prefix(12))... (\(completedCount)/\(total))", "INFO")
                } else {
                    logMessage?("Failed to download blob (\(completedCount)/\(total))", "WARN")
                }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) blobs from external servers")
        logMessage?("Server mirror phase: \(mirrored)/\(total) blob(s) downloaded successfully", "INFO")
        return mirrored
    }

    /// Mirror media from note events (kind 1063 file metadata) that aren't already stored locally.
    /// Unlike mirrorAllFromExternal (which only checks configured mirrors via BUD-04), this scans
    /// the actual media URLs from synced notes — handling media on any server (e.g., Primal's blossom).
    /// - Parameter noteMedia: The array of MediaItem from nostrService.noteMedia
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorFromNoteMedia(_ noteMedia: [MediaItem], progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
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
            logMessage?("All note media already exists locally", "INFO")
            return 0
        }

        logger.info("Found \(urlsToMirror.count) media items from notes to mirror locally")
        logMessage?("\(urlsToMirror.count) media item(s) missing locally — downloading...", "INFO")
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
                        if success {
                            mirrored += 1
                            logMessage?("Mirrored \(url.lastPathComponent.prefix(20))... from \(url.host ?? "remote") (\(completedCount)/\(total))", "INFO")
                        } else {
                            logMessage?("Failed \(url.lastPathComponent.prefix(20))... from \(url.host ?? "remote") (\(completedCount)/\(total))", "WARN")
                        }
                        progress?(completedCount, total)
                    }
                    // Throttle to avoid overwhelming the relay
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                group.addTask {
                    await self.downloadFromURL(url: url)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success {
                    mirrored += 1
                    logMessage?("Mirrored media (\(completedCount)/\(total))", "INFO")
                } else {
                    logMessage?("Failed to mirror media (\(completedCount)/\(total))", "WARN")
                }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) media from note events")
        logMessage?("Note media phase: \(mirrored)/\(total) item(s) downloaded successfully", "INFO")
        return mirrored
    }
}
