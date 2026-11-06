import Foundation

extension BlossomService {
    /// Delete everywhere on the owner's mesh devices (`MeshDeleteTargets`):
    /// a BUD-02 DELETE through each device's loopback mesh ingress, then a
    /// HEAD that must answer 404, as Android's `deleteOverMesh`. Signed by
    /// this device's own mesh key, never the owner's
    /// (docs/MESH_COPY_V2_CONTRACT.md §2.1): one delete naming every target
    /// in `p`, and one get for the checks. Results are keyed
    /// `fipsmesh://<npub>/`, with the device's name for the leftover text.
    /// Nothing here touches DNS: the ingress is `127.0.0.1`.
    func deleteFromMeshDevices(sha256: String, includeHomeVault: Bool) async -> MirrorDeleteResult {
        let targets = await MainActor.run { Self.meshDeleteTargets(includeHomeVault: includeHomeVault) }
        var result = MirrorDeleteResult()
        guard !targets.isEmpty else { return result }
        for target in targets { result.names[target.key] = target.name }

        let receivers = targets.map(\.npub)
        let deviceDelete = MeshKeyAuth.blossomTags(verb: .delete, sha256s: [sha256], receivers: receivers)
            .flatMap { MeshKeySigner.authorization(kind: 24242, content: "Delete blob \(sha256.prefix(8))...", tags: $0) }
        let deviceCheck = MeshKeyAuth.blossomTags(verb: .get, sha256s: [sha256], receivers: receivers)
            .flatMap { MeshKeySigner.authorization(kind: 24242, content: "Check blob \(sha256.prefix(8))...", tags: $0) }
        // TODO(mesh-key): the owner's token, only for a vault that turns the
        // device form down (or with no mesh key here); signed once if needed.
        var ownerAuth: String??
        func owner() async -> String? {
            if let ownerAuth { return ownerAuth }
            let tags = MeshDeleteTargets.authTags(sha256: sha256, targets: targets)
            let signed: String? = await {
                guard let event = await nostrService.signEventAsync(
                    kind: 24242, content: "Delete blob \(sha256.prefix(8))...", tags: tags, forceOwner: true),
                      let json = try? JSONEncoder().encode(event) else { return nil }
                return json.base64EncodedString()
            }()
            ownerAuth = .some(signed)
            return signed
        }

        for target in targets {
            var outcome: (gone: Bool, deleteStatus: Int)?
            if let deviceDelete {
                outcome = await Self.deleteOverMesh(npub: target.npub, sha256: sha256, auth: deviceDelete, checkAuth: deviceCheck)
            }
            if outcome == nil || (outcome?.gone == false && MeshKeyAuth.retriesWithOwnerForm(status: outcome?.deleteStatus ?? 0)) {
                if let auth = await owner() {
                    outcome = await Self.deleteOverMesh(npub: target.npub, sha256: sha256, auth: auth, checkAuth: auth)
                } else {
                    logger.error("Mesh delete: no mesh key and no owner's token")
                }
            }
            if outcome?.gone == true { result.deleted.append(target.key) } else { result.failed.append(target.key) }
        }
        return result
    }

    /// The owner's devices, from My Devices on this platform.
    @MainActor
    private static func meshDeleteTargets(includeHomeVault: Bool) -> [MeshDeleteTarget] {
        let config = ConfigService.shared.config
        #if os(iOS)
        let devices = FipsMeshDevices.current(config)
        let own = FipsMeshService.shared.ownMeshNpub ?? FipsMeshService.meshNpubFromKey()
        #else
        let devices = config.meshDevices
        let own = MacFipsMeshService.shared.ownNpub
        #endif
        return MeshDeleteTargets.of(devices: devices, ownNpub: own, includeHomeVault: includeHomeVault)
    }

    @MainActor
    private static func ingress(_ npub: String) async -> URL? {
        #if os(iOS)
        return await FipsMeshService.shared.ingressURL(meshNpub: npub)
        #else
        return await MacFipsMeshService.shared.ingressURL(meshNpub: npub)
        #endif
    }

    /// Right after the engine starts the link may still be coming up and drop
    /// the first tries, so a dropped connection is tried again for a while.
    /// The ingress URL carries a token: logged by npub only.
    private static func deleteOverMesh(npub: String, sha256: String, auth: String, checkAuth: String?) async -> (gone: Bool, deleteStatus: Int) {
        let giveUp = Date().addingTimeInterval(30)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        while true {
            guard let base = await ingress(npub) else {
                print("Mesh delete \(npub.prefix(12)): vault not reachable")
                return (false, 0)
            }
            var delete = URLRequest(url: base.appendingPathComponent(sha256))
            delete.httpMethod = "DELETE"
            delete.timeoutInterval = 30
            delete.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
            do {
                let (_, deleteResponse) = try await session.data(for: delete)
                let deleteStatus = (deleteResponse as? HTTPURLResponse)?.statusCode ?? 0
                let check = HomeVaultLogic.vaultCheckRequest(sha256: sha256, base: base, authBase64: checkAuth)
                let checkStatus = (try? await session.data(for: check))
                    .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                let gone = MeshDeleteTargets.gone(deleteStatus: deleteStatus, checkStatus: checkStatus)
                if !gone {
                    print("Mesh delete \(npub.prefix(12)): DELETE \(deleteStatus), then HEAD \(checkStatus.map(String.init) ?? "no answer")")
                }
                return (gone, deleteStatus)
            } catch {
                guard Date().addingTimeInterval(2) < giveUp else {
                    print("Mesh delete \(npub.prefix(12)) failed: \(error.localizedDescription)")
                    return (false, 0)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
