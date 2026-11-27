import Foundation

/// "Delete from this device" (A3, plan RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md
/// §4): removes this device's vault copy of one file and keeps it on the
/// servers. The file goes only after a fresh check proves another place holds
/// the same bytes (`DeleteHereGate`), and it goes on the "removed here" list
/// first (`DeviceRemovedStore`) so Auto-Mirror (servers and note media)
/// never pulls it back. Twin: Android `service/blossom/BlossomServiceDeleteHere.kt`.
extension BlossomService {
    enum DeleteHereResult: Equatable {
        case deleted(holders: [String])
        case refused(String)
        case failed(String)
    }

    func deleteHere(sha256: String) async -> DeleteHereResult {
        let hash = sha256.lowercased()
        guard MediaSizeCache.isHash(hash) else { return .refused("This isn't a vault file.") }
        let (relayDataDir, blossomPath, owner, servers, ownHosts) = await MainActor.run { () -> (URL, String, String, [String], Set<String>) in
            let config = configService.config
            #if os(iOS)
            // On a phone the owner's Mac or box is a real second copy (Logen, 2026-11-27).
            let all = config.activeBlossomMirrors + config.vaultMediaServers
            let own: Set<String> = []
            #else
            // On a Mac its own relay and the other vaults are never counted:
            // only media servers can prove the copy.
            let all = config.activeBlossomMirrors.filter { !HavenConfig.isHomeNetworkServer($0) }
            // Its own tunnel domain too: it can reach Media Servers by hand or by 10063 adoption (Tron, PR 2652 M1).
            var own = Set(config.vaultMediaServers.compactMap { URL(string: $0)?.host?.lowercased() })
            if let host = DeleteHereGate.relayHost(config.sanitizedRelayURL) { own.insert(host) }
            #endif
            return (configService.relayDataDir, config.blossomPath, nostrService.ownerHexPubkey, all, own)
        }
        let vault = relayDataDir.appendingPathComponent(blossomPath)
        let store = DeviceRemovedStore.shared
        store.recoverSetAside(relayDataDir: relayDataDir, vault: vault)
        guard let file = Self.localVaultFile(hash: hash, in: vault),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            return .refused("This file isn't on this device.")
        }
        let candidates = DeleteHereGate.candidates(servers.filter { !MeshDeleteTargets.isMeshAddress($0) }, ownHosts: ownHosts)
        guard !candidates.isEmpty else {
            return .refused("No media server or other device to keep it. Copy it to a server first.")
        }

        // On the list first, so a run starting now skips it; then out of the
        // vault folder, so no address of this device can answer the check
        // with its own copy (Tron, PR 2652 M1).
        guard store.add(hash, owner: owner, relayDataDir: relayDataDir) else {
            return .failed("Couldn't save the list of files removed here, so nothing was deleted.")
        }
        guard let aside = store.setAside(file, sha256: hash, relayDataDir: relayDataDir) else {
            store.remove(hash, relayDataDir: relayDataDir)
            return .failed("Couldn't remove the file from this device.")
        }
        defer { store.finished(hash) }
        func putBack() {
            if (try? FileManager.default.moveItem(at: aside, to: file)) != nil {
                store.remove(hash, relayDataDir: relayDataDir)
            } else {
                // Left aside and listed: the next delete-here run puts it back.
                logger.error("deleteHere: \(hash.prefix(8)) not put back; recovered on the next run")
            }
        }

        // Asked now, every one, no cached answer.
        let answers = await withTaskGroup(of: (String, DeleteHereGate.Answer?).self) { group in
            for server in candidates { group.addTask { (server, await self.deleteHereProbe(server: server, sha256: hash)) } }
            var out: [String: DeleteHereGate.Answer?] = [:]
            for await (server, answer) in group { out[server] = answer }
            return out
        }
        let decision = DeleteHereGate.decide(answers: answers, sha256: hash, localSize: size)
        guard case .allowed(let holders) = decision else {
            putBack()
            if case .refused(let why) = decision { return .refused(why) }
            return .refused("Not deleted.")
        }
        do {
            try FileManager.default.removeItem(at: aside)
        } catch {
            putBack()
            logger.error("deleteHere: \(hash.prefix(8)) not removed: \(error.localizedDescription)")
            return .failed("Couldn't remove the file from this device.")
        }
        #if os(iOS)
        await MainActor.run { HomeVaultSender.shared.forget(blobSha256: hash) }
        #endif
        logger.info("deleteHere: removed \(hash.prefix(8)) from this device; held by \(holders.count) server(s)")
        return .deleted(holders: holders)
    }

    /// `<hash>` or `<hash>.<ext>` in the vault folder, nil when not here.
    static func localVaultFile(hash: String, in dir: URL) -> URL? {
        let exact = dir.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.first { $0.lowercased().hasPrefix(hash + ".") }.map { dir.appendingPathComponent($0) }
    }

    /// One server's headers for `GET <server>/<hash>` with `Range: bytes=0-0`
    /// (a GET, not HEAD: some servers keep answering HEAD for blobs they have
    /// dropped). nil when it could not be asked.
    private func deleteHereProbe(server: String, sha256: String) async -> DeleteHereGate.Answer? {
        guard let url = DeleteHereGate.probeURL(server: server, sha256: sha256, nonce: UUID().uuidString.lowercased()) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        do {
            let (bytes, response) = try await remoteSession.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return nil }
            return DeleteHereGate.Answer(status: http.statusCode,
                                         contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                         contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                                         contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                                         finalURL: http.url,
                                         cacheStatus: http.value(forHTTPHeaderField: "cf-cache-status") ?? http.value(forHTTPHeaderField: "x-cache"),
                                         age: http.value(forHTTPHeaderField: "Age"))
        } catch {
            return nil
        }
    }

    /// The relay data folder, where the "removed here" list lives.
    /// First puts back any file a delete left aside when the app quit mid-check.
    func removedHereDir() async -> URL {
        let (dir, vault) = await MainActor.run {
            (configService.relayDataDir, configService.relayDataDir.appendingPathComponent(configService.config.blossomPath))
        }
        DeviceRemovedStore.shared.recoverSetAside(relayDataDir: dir, vault: vault)
        return dir
    }

    /// `hashes` without the ones removed from this device (every pass that
    /// fills the vault on its own calls this).
    func withoutRemovedHere(_ hashes: [String]) async -> [String] {
        DeviceRemovedStore.shared.keeping(hashes, relayDataDir: await removedHereDir())
    }

    /// An explicit Save to Vault of `sha256`: it may come back.
    func clearRemovedHere(_ sha256: String) async {
        DeviceRemovedStore.shared.remove(sha256, relayDataDir: await removedHereDir())
    }
}
