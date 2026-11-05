import Foundation

extension BlossomService {
    /// Delete everywhere on the owner's mesh devices (`MeshDeleteTargets`):
    /// a BUD-02 DELETE through each device's loopback mesh ingress, then a
    /// HEAD that must answer 404, as Android's `deleteOverMesh`. One owner
    /// token covers every device. Results are keyed `fipsmesh://<npub>/`, with
    /// the device's name for the leftover text. Nothing here touches DNS: the
    /// ingress is `127.0.0.1`.
    func deleteFromMeshDevices(sha256: String, includeHomeVault: Bool) async -> MirrorDeleteResult {
        let targets = await MainActor.run { Self.meshDeleteTargets(includeHomeVault: includeHomeVault) }
        var result = MirrorDeleteResult()
        guard !targets.isEmpty else { return result }
        for target in targets { result.names[target.key] = target.name }

        let tags = MeshDeleteTargets.authTags(sha256: sha256, targets: targets)
        let auth: String? = await {
            guard let event = await nostrService.signEventAsync(
                kind: 24242, content: "Delete blob \(sha256.prefix(8))...", tags: tags, forceOwner: true),
                  let json = try? JSONEncoder().encode(event) else { return nil }
            return json.base64EncodedString()
        }()

        for target in targets {
            let gone: Bool
            if let auth {
                gone = await Self.deleteOverMesh(npub: target.npub, sha256: sha256, auth: auth)
            } else {
                logger.error("Mesh delete: could not sign the owner's token")
                gone = false
            }
            if gone { result.deleted.append(target.key) } else { result.failed.append(target.key) }
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
    private static func deleteOverMesh(npub: String, sha256: String, auth: String) async -> Bool {
        let giveUp = Date().addingTimeInterval(30)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        while true {
            guard let base = await ingress(npub) else {
                print("Mesh delete \(npub.prefix(12)): vault not reachable")
                return false
            }
            var delete = URLRequest(url: base.appendingPathComponent(sha256))
            delete.httpMethod = "DELETE"
            delete.timeoutInterval = 30
            delete.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
            do {
                let (_, deleteResponse) = try await session.data(for: delete)
                let deleteStatus = (deleteResponse as? HTTPURLResponse)?.statusCode ?? 0
                let check = HomeVaultLogic.vaultCheckRequest(sha256: sha256, base: base, authBase64: auth)
                let checkStatus = (try? await session.data(for: check))
                    .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                let gone = MeshDeleteTargets.gone(deleteStatus: deleteStatus, checkStatus: checkStatus)
                if !gone {
                    print("Mesh delete \(npub.prefix(12)): DELETE \(deleteStatus), then HEAD \(checkStatus.map(String.init) ?? "no answer")")
                }
                return gone
            } catch {
                guard Date().addingTimeInterval(2) < giveUp else {
                    print("Mesh delete \(npub.prefix(12)) failed: \(error.localizedDescription)")
                    return false
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
