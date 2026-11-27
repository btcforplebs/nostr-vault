import Foundation

/// "Delete from this device" (A3, plan RESEARCH/NV_MEDIA_LIST_SIZE_2026_11_26.md
/// §4): removes this device's vault copy of one file and keeps it on the
/// servers. The file goes only after a fresh check proves another place holds
/// the same bytes (`DeleteHereGate`), and it goes on the owner's "removed
/// here" list first (`DeviceRemovedStore`) so Auto-Mirror and the imports
/// never pull it back. Twin: Android `service/blossom/BlossomServiceDeleteHere.kt`.
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
            let own = Set(config.vaultMediaServers.compactMap { URL(string: $0)?.host?.lowercased() })
            #endif
            return (configService.relayDataDir, config.blossomPath, nostrService.ownerHexPubkey, all, own)
        }
        let vault = relayDataDir.appendingPathComponent(blossomPath)
        guard let file = Self.localVaultFile(hash: hash, in: vault),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            return .refused("This file isn't on this device.")
        }
        let candidates = DeleteHereGate.candidates(servers.filter { !MeshDeleteTargets.isMeshAddress($0) }, ownHosts: ownHosts)

        // Asked now, every one, no cached answer.
        let answers = await withTaskGroup(of: (String, DeleteHereGate.Answer?).self) { group in
            for server in candidates { group.addTask { (server, await self.deleteHereProbe(server: server, sha256: hash)) } }
            var out: [String: DeleteHereGate.Answer?] = [:]
            for await (server, answer) in group { out[server] = answer }
            return out
        }
        let decision = DeleteHereGate.decide(answers: answers, sha256: hash, localSize: size)
        guard case .allowed(let holders) = decision else {
            if case .refused(let why) = decision { return .refused(why) }
            return .refused("Not deleted.")
        }

        // On the list before the file goes, so a run starting now skips it.
        guard DeviceRemovedStore.shared.add(hash, owner: owner, vault: vault) else {
            return .failed("Couldn't save the list of files removed here, so nothing was deleted.")
        }
        #if os(iOS)
        await MainActor.run { HomeVaultSender.shared.forget(blobSha256: hash) }
        #endif
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            DeviceRemovedStore.shared.remove(hash, owner: owner, vault: vault)
            logger.error("deleteHere: \(hash.prefix(8)) not removed: \(error.localizedDescription)")
            return .failed("Couldn't remove the file from this device.")
        }
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
        guard var base = URL(string: server) else { return nil }
        if base.scheme == "http", var c = URLComponents(url: base, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            if let u = c.url { base = u }
        }
        var request = URLRequest(url: base.appendingPathComponent(sha256))
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
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
                                         finalURL: http.url)
        } catch {
            return nil
        }
    }

    /// The vault folder and its owner, for the "removed here" list.
    func removedHereScope() async -> (vault: URL, owner: String) {
        await MainActor.run {
            (configService.relayDataDir.appendingPathComponent(configService.config.blossomPath), nostrService.ownerHexPubkey)
        }
    }

    /// `hashes` without the ones removed from this device (every pass that
    /// fills the vault on its own calls this).
    func withoutRemovedHere(_ hashes: [String]) async -> [String] {
        let (vault, owner) = await removedHereScope()
        return DeviceRemovedStore.shared.keeping(hashes, owner: owner, vault: vault)
    }

    /// An explicit Save to Vault of `sha256`: it may come back.
    func clearRemovedHere(_ sha256: String) async {
        let (vault, owner) = await removedHereScope()
        DeviceRemovedStore.shared.remove(sha256, owner: owner, vault: vault)
    }
}
