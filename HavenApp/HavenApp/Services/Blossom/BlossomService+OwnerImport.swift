import Foundation
import os.log

extension BlossomService {
    /// This device's account has no key here and no signer (npub only). Its
    /// files go into its own vault in-process (`OwnVaultUpload`).
    var vaultIsKeyless: Bool {
        get async { await MainActor.run { FeedService.activeAccountIsReadOnly } }
    }

    /// Hands one file to this device's vault with no signature: the vault
    /// stores it as the owner's after checking it hashes to `sha256`. Only
    /// this app can call it (it is not an HTTP route). A `.data` source goes
    /// through a temp file, deleted afterwards.
    func importToOwnVaultInProcess(source: UploadSource, sha256: String, contentType: String) async -> Bool {
        let relayReady = await RelayProcessManager.shared.ensureRelayServing()
        guard relayReady else {
            logger.error("importToOwnVaultInProcess: relay not serving")
            return false
        }
        let path: URL
        var temp: URL?
        switch source {
        case .file(let url):
            path = url
        case .data(let data):
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(sha256.prefix(16))-\(UUID().uuidString).blob")
            do {
                try data.write(to: url)
            } catch {
                logger.error("importToOwnVaultInProcess: temp write failed: \(error.localizedDescription)")
                return false
            }
            path = url
            temp = url
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
        let stored = await Task.detached(priority: .utility) {
            withCStrings([path.path, sha256, contentType]) { p in ImportOwnerBlobC(p[0], p[1], p[2]) }
        }.value == 1
        if stored {
            logger.info("importToOwnVaultInProcess: \(sha256.prefix(8)) stored in-process")
        } else {
            logger.warning("importToOwnVaultInProcess: vault refused \(sha256.prefix(8))")
        }
        return stored
    }
}
