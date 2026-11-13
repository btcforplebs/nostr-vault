import Foundation

/// A save from the Media tab (Magic Paste, photo picker, Files) runs the same
/// tail a post's upload does (`uploadAndMirror`): on iPhone/iPad the blob goes
/// on the home vault's lane, then a file note tells the owner's other open
/// Media tabs. Before this a Magic Paste on the iPhone stayed on the iPhone
/// (2026-11-13). The rule for the note is `HomeVaultLogic.mediaSaveNoteServers`.
extension BlossomService {
    func saveFromMediaTab(data: Data, sha256: String, contentType: String, mirrorToExternal: Bool = true) async -> Bool {
        await saveFromMediaTab(source: .data(data), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal, progress: nil)
    }

    func saveFromMediaTab(fileURL: URL, sha256: String, contentType: String, mirrorToExternal: Bool = true,
                          progress: ((Double) -> Void)? = nil) async -> Bool {
        await saveFromMediaTab(source: .file(fileURL), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal, progress: progress)
    }

    private func saveFromMediaTab(source: UploadSource, sha256: String, contentType: String, mirrorToExternal: Bool,
                                  progress: ((Double) -> Void)?) async -> Bool {
        guard let saved = await storeLocally(source: source, sha256: sha256, contentType: contentType,
                                             mirrorToExternal: mirrorToExternal, progress: progress) else { return false }
        let size = source.byteCount
        #if os(iOS)
        let configured = await MainActor.run { configService.config.activeBlossomMirrors }
        let signer = await MainActor.run { nostrService.activeHexPubkey }
        let forwardTo = await MainActor.run {
            HomeVaultLogic.forwardServer(phoneMirrors: configured, ownerServerList: nostrService.serverLists[signer] ?? [])
        }
        let toHomeVault = await MainActor.run {
            HomeVaultSender.shared.enqueue(blobSha256: sha256, contentType: contentType, signer: signer, byteCount: size, forwardTo: forwardTo)
        }
        let isVault = false
        #else
        let toHomeVault = false
        let isVault = true
        #endif
        if let servers = HomeVaultLogic.mediaSaveNoteServers(configured: saved.mirrors, accepted: saved.accepted,
                                                             toHomeVault: toHomeVault, isVault: isVault) {
            await noteFileUploaded(sha256: sha256, contentType: contentType, size: size, servers: servers)
        }
        return true
    }
}
