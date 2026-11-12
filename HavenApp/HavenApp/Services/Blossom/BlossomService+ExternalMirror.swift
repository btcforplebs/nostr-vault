import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Mirror all owner media from external Blossom servers to local storage
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorAllFromExternal(progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
        var limit = AutoMirrorRunLimit.unlimited
        return await mirrorAllFromExternal(limit: &limit, progress: progress, logMessage: logMessage)
    }

    /// The same, downloading at most what `limit` has left (one run's cap).
    func mirrorAllFromExternal(limit: inout AutoMirrorRunLimit, progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
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
        let keyless = await vaultIsKeyless

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
        // Each blob's server upload time, so a copy keeps its real date.
        var descriptorDates: [(sha256: String?, uploaded: Int?)] = []
        // One BUD-02 list authorisation (kind 24242) for every server, so servers
        // that require authentication return blob lists instead of empty/403.
        // A keyless vault signs nothing (no signer to ask); the list is asked for unsigned.
        let listAuthTags = [["t", "list"], ["expiration", String(Int64(Date().timeIntervalSince1970) + 3600)]]
        let listAuthEvent = keyless ? nil : await nostrService.signEventAsync(kind: 24242, content: "List blobs", tags: listAuthTags)
        let listAuthHeader = listAuthEvent.flatMap { try? JSONEncoder().encode($0) }.map { "Nostr \($0.base64EncodedString())" }
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else { continue }

            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url { mirrorURL = secureURL }
            }

            logMessage?("Querying \(mirror) for blob list...", "INFO")


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
                        descriptorDates.append((desc.sha256, desc.uploaded))
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
        let heldBefore = limit.held
        let sortedHashes = limit.take(Array(missingHashes).sorted())
        if limit.held > heldBefore {
            logMessage?("\(limit.held - heldBefore) blob(s) left for the next run (at most \(AutoMirrorRunLimit.maxDownloads) per run)", "INFO")
        }
        let uploadedDates = CopiedInDate.uploadedByHash(descriptorDates)
        var mirrored = 0
        var completedCount = 0
        let total = sortedHashes.count
        let plan = await autoMirrorSigningPlan()
        let groupSize = Self.autoMirrorGroupSize

        // A group at a time: download, then save with at most one signature.
        for start in stride(from: 0, to: total, by: groupSize) {
            let group = Array(sortedHashes[start..<min(start + groupSize, total)])
            let fetched = await autoMirrorFetch(group) { hash in await self.fetchFromMirrors(sha256: hash) }
            let files = fetched.map(\.1)
            let result = await autoMirrorStore(files, plan: plan, dates: uploadedDates)
            files.forEach { try? FileManager.default.removeItem(at: $0.url) }
            let inVault = group.filter { result.inVault.contains($0.lowercased()) }.count
            mirrored += result.new
            completedCount += group.count
            logMessage?("Saved \(result.new) blob(s); \(inVault) of \(group.count) now here (\(completedCount)/\(total))", inVault == group.count ? "INFO" : "WARN")
            progress?(completedCount, total)
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
        var limit = AutoMirrorRunLimit.unlimited
        return await mirrorFromNoteMedia(noteMedia, limit: &limit, progress: progress, logMessage: logMessage)
    }

    /// The same, downloading at most what `limit` has left (one run's cap).
    func mirrorFromNoteMedia(_ noteMedia: [MediaItem], limit: inout AutoMirrorRunLimit, progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let ownerPubkey = await MainActor.run { nostrService.ownerHexPubkey }
        let whitelistedPubkeys = await MainActor.run { configService.whitelistedHexPubkeys }

        let localHashes = await vaultBlobHashes()
        // What earlier runs saved: a link not named by its hash is otherwise
        // downloaded again on every run (AutoMirrorLedger).
        var ledger = AutoMirrorLedger.load(from: relayDataDir)

        // Find remote media URLs from owner or whitelisted accounts that aren't stored locally
        var candidates: [URL] = []
        // A note's imeta `x` names the file before any download (rule 1).
        var knownHashes: [String: String] = [:]
        // The note's created_at goes on the copied file (newest note wins, as in the grid).
        let noteDates = CopiedInDate.newestByKey(noteMedia, key: { $0.url.absoluteString }, date: { $0.dateAdded })
        for item in noteMedia {
            guard let pubkey = item.pubkey,
                  pubkey == ownerPubkey ||
                  whitelistedPubkeys.contains(pubkey) else { continue }
            // Skip local URLs, and host-less ones that can never load
            let host = item.url.host?.lowercased() ?? ""
            if host.isEmpty { continue }
            if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" { continue }
            candidates.append(item.url)
            if let tags = item.tags {
                knownHashes.merge(AutoMirrorLedger.imetaHashes(tags)) { first, _ in first }
            }
        }
        let wanted = ledger.toDownload(candidates, localHashes: localHashes, knownHashes: knownHashes)
        guard !wanted.isEmpty else {
            logger.info("No missing media found in note events")
            logMessage?("All note media already exists locally", "INFO")
            return 0
        }
        let heldBefore = limit.held
        let urlsToMirror = limit.take(wanted)
        if limit.held > heldBefore {
            logMessage?("\(limit.held - heldBefore) media item(s) left for the next run (at most \(AutoMirrorRunLimit.maxDownloads) per run)", "INFO")
        }

        guard !urlsToMirror.isEmpty else {
            logMessage?("This run's \(AutoMirrorRunLimit.maxDownloads) downloads are used up; the rest come next run", "INFO")
            return 0
        }

        logger.info("Found \(urlsToMirror.count) media items from notes to mirror locally")
        logMessage?("\(urlsToMirror.count) media item(s) missing locally — downloading...", "INFO")
        var mirrored = 0
        var completedCount = 0
        let total = urlsToMirror.count
        let plan = await autoMirrorSigningPlan()
        let groupSize = Self.autoMirrorGroupSize

        // A group at a time: download, save with at most one signature, then
        // remember each link saved, so a run stopped part way resumes here.
        for start in stride(from: 0, to: total, by: groupSize) {
            let group = Array(urlsToMirror[start..<min(start + groupSize, total)])
            let fetched = await autoMirrorFetch(group) { url in await self.fetchFromURL(url) }
            var dates: [String: Date] = [:]
            for (url, file) in fetched { dates[file.sha256.lowercased()] = noteDates[url.absoluteString] }
            let result = await autoMirrorStore(fetched.map(\.1), plan: plan, dates: dates)
            fetched.forEach { try? FileManager.default.removeItem(at: $0.1.url) }
            var here = 0
            for (url, file) in fetched where result.inVault.contains(file.sha256.lowercased()) {
                ledger.remember(url: url, sha256: file.sha256)
                here += 1
            }
            do { try ledger.save(to: relayDataDir) } catch {
                appLog("Auto-Mirror: could not write \(AutoMirrorLedger.fileName): \(error.localizedDescription)", level: "WARN")
            }
            mirrored += result.new
            completedCount += group.count
            logMessage?("Saved \(result.new) media item(s); \(here) of \(group.count) now here (\(completedCount)/\(total))", here == group.count ? "INFO" : "WARN")
            progress?(completedCount, total)
        }

        logger.info("Mirrored \(mirrored)/\(total) media from note events")
        logMessage?("Note media phase: \(mirrored)/\(total) item(s) downloaded successfully", "INFO")
        return mirrored
    }
}
