import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Returns the local Blossom server URL string
    func localBlossomURL() async -> String {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        return "http://127.0.0.1:\(port)"
        #else
        return "https://localhost:\(port)"
        #endif
    }

    /// Which mirrors a delete reached. A delete is only done when `failed` is
    /// empty: the file is still public on every server listed there.
    struct MirrorDeleteResult {
        var deleted: [String] = []
        var failed: [String] = []

        var allDeleted: Bool { failed.isEmpty && !deleted.isEmpty }

        /// Hosts still holding the file, for the banner ("blossom.primal.net").
        var failedHosts: [String] {
            failed.map { URL(string: $0)?.host ?? $0 }
        }
    }

    /// What a Delete everywhere left behind, or nil when nothing is left.
    /// Names each place so a partial delete can't pass for a full one.
    static func deleteEverywhereLeftover(localDeleted: Bool, mirrors: MirrorDeleteResult) -> String? {
        var places = mirrors.failedHosts
        if !localDeleted { places.append("this device") }
        guard !places.isEmpty else { return nil }
        return "Still on " + ListFormatter.localizedString(byJoining: places)
    }

    /// Delete media from every server that may hold it and report each one.
    /// One mirror succeeding used to count as success, so a file left on two
    /// of three servers was reported as deleted. The servers are
    /// `HavenConfig.blossomDeleteTargets`: `photoURL` adds the server in the
    /// file's own link, and `includeHomeVault` false ("Delete from mirrors")
    /// sends nothing to any of the owner's vaults: home-network and mesh
    /// addresses are not targets, and every other server is asked first
    /// whether it is a vault (NIP-11 pubkey = owner). One that can't be asked
    /// is reported as still holding the file.
    func deleteFromMirrorsReport(sha256: String, photoURL: URL?, includeHomeVault: Bool) async -> MirrorDeleteResult {
        let (targets, ownerHex) = await MainActor.run {
            (configService.config.blossomDeleteTargets(
                ownerServerList: nostrService.serverLists[nostrService.activeHexPubkey] ?? [],
                photoURL: photoURL, includeHomeVault: includeHomeVault),
             nostrService.activeHexPubkey)
        }
        guard !targets.isEmpty else {
            logger.warning("No Blossom mirrors configured for deletion")
            return MirrorDeleteResult()
        }

        var result = MirrorDeleteResult()
        var mirrors = targets
        if !includeHomeVault {
            // "Delete from mirrors" must never reach one of the owner's own
            // vaults, whatever name it is listed under (another phone's Mac
            // in 10063): that copy may be the last one.
            let verdicts = await vaultCheckVerdicts(targets, ownerHex: ownerHex)
            mirrors = targets.filter { verdicts[$0] == .mirror }
            for server in targets where verdicts[server] == .ownVault {
                logger.info("Skipping \(server): it is one of the owner's vaults")
            }
            for server in targets where verdicts[server] == .unknown {
                logger.warning("Not deleting from \(server): couldn't check it isn't a vault")
                result.failed.append(server)
            }
        }
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else {
                result.failed.append(mirror)
                continue
            }

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

            // One token per server, naming it (BlossomDeleteAuth).
            let authTags = BlossomDeleteAuth.tags(sha256: sha256, deleteURL: deleteURL)

            let authContent = "Delete blob \(sha256.prefix(8))..."

            guard let authEvent = await nostrService.signEventAsync(kind: 24242, content: authContent, tags: authTags) else {
                logger.error("Failed to create Blossom auth event for deletion from \(mirror)")
                result.failed.append(mirror)
                continue
            }

            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event for deletion from \(mirror)")
                result.failed.append(mirror)
                continue
            }

            let authBase64 = authJSON.base64EncodedString()
            request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")

            do {
                let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...204).contains(status) {
                    logger.info("Successfully deleted \(sha256.prefix(8)) from mirror \(mirror)")
                    result.deleted.append(mirror)
                } else if status == 404 {
                    logger.info("Confirmed \(sha256.prefix(8)) is already absent from mirror \(mirror)")
                    result.deleted.append(mirror)
                } else {
                    let bodyString = String(data: data, encoding: .utf8) ?? "(binary/empty)"
                    logger.warning("Failed to delete from \(mirror) with status \(status), response: \(bodyString)")
                    result.failed.append(mirror)
                }
            } catch {
                logger.error("Error deleting from \(mirror): \(error.localizedDescription)")
                result.failed.append(mirror)
            }
        }

        return result
    }

    /// Delete media from local Blossom storage
    /// - Parameter sha256: The SHA256 hash of the media to delete
    /// - Returns: true if the file is gone (deleted, or was never stored here)
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

        // Nothing to delete is the outcome asked for, like a mirror's 404.
        logger.info("Media file already absent from local storage: \(sha256.prefix(8))")
        return true
    }

    /// Asks each server for its relay info (NIP-11) to tell the owner's
    /// vaults from public mirrors (`HavenConfig.vaultCheckVerdict`).
    private func vaultCheckVerdicts(_ servers: [String], ownerHex: String) async -> [String: HavenConfig.VaultCheckVerdict] {
        await withTaskGroup(of: (String, HavenConfig.VaultCheckVerdict).self) { group in
            for server in servers {
                group.addTask { [remoteSession] in
                    guard var components = URLComponents(string: server) else { return (server, .unknown) }
                    if components.scheme == "http" { components.scheme = "https" }
                    guard let url = components.url else { return (server, .unknown) }
                    var request = URLRequest(url: url)
                    request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 15
                    // A server error (a tunnel whose vault is down) is no answer.
                    var info: Data?
                    if let (data, response) = try? await remoteSession.data(for: request),
                       ((response as? HTTPURLResponse)?.statusCode ?? 0) < 500 { info = data }
                    return (server, HavenConfig.vaultCheckVerdict(info: info, ownerHex: ownerHex))
                }
            }
            var verdicts: [String: HavenConfig.VaultCheckVerdict] = [:]
            for await (server, verdict) in group { verdicts[server] = verdict }
            return verdicts
        }
    }

    /// Check if a URL is localhost
    func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }
}
