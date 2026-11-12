import Foundation
import os.log

/// How Auto-Mirror saves what it downloads: files already in the vault are
/// not saved again, the owner's files go in without a signer, and another
/// account signs once per batch (`AutoMirrorSigning`).
extension BlossomService {
    /// Links or hashes taken this many at a time: one download group, at
    /// most one signature, then the temp files are gone.
    static let autoMirrorGroupSize = 50

    /// How this run's files get into the vault.
    func autoMirrorSigningPlan() async -> AutoMirrorSigning {
        let keyless = await vaultIsKeyless
        let activeIsOwner = await MainActor.run { nostrService.activeHexPubkey == nostrService.ownerHexPubkey }
        return AutoMirrorSigning.plan(keyless: keyless, activeIsOwner: activeIsOwner)
    }

    /// The hashes of the files in this vault's media folder now.
    func vaultBlobHashes() async -> Set<String> {
        let dir = await MainActor.run { configService.relayDataDir.appendingPathComponent(configService.config.blossomPath) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(files.filter { !$0.starts(with: ".") && $0 != "LOCK" }.map { $0.lowercased() })
    }

    /// Downloads `items` four at a time; the ones that came, with their temp files.
    func autoMirrorFetch<T: Sendable>(_ items: [T], fetch: @escaping @Sendable (T) async -> StreamingBlobDownload.File?) async -> [(T, StreamingBlobDownload.File)] {
        await withTaskGroup(of: (T, StreamingBlobDownload.File?).self) { group in
            var fetched: [(T, StreamingBlobDownload.File)] = []
            var next = 0
            func collect(_ result: (T, StreamingBlobDownload.File?)) {
                if let file = result.1 { fetched.append((result.0, file)) }
            }
            for item in items {
                if next >= 4, let result = await group.next() { collect(result) }
                group.addTask { (item, await fetch(item)) }
                next += 1
            }
            for await result in group { collect(result) }
            return fetched
        }
    }

    /// Saves downloaded files into this vault. `inVault`: the hashes now in
    /// it, including ones that already were; `new`: how many this saved.
    /// Temp files are left to the caller.
    func autoMirrorStore(_ files: [StreamingBlobDownload.File], plan: AutoMirrorSigning,
                         dates: [String: Date] = [:]) async -> (inVault: Set<String>, new: Int) {
        var inVault = Set<String>()
        var toStore: [StreamingBlobDownload.File] = []
        let local = await vaultBlobHashes()
        for file in files {
            switch AutoMirrorSave.decide(sha256: file.sha256, localHashes: local.union(inVault)) {
            case .alreadyHere: inVault.insert(file.sha256.lowercased())
            case .store:
                if !toStore.contains(where: { $0.sha256 == file.sha256 }) { toStore.append(file) }
            }
        }
        guard !toStore.isEmpty else {
            if !files.isEmpty { appLog("Auto-Mirror: \(files.count) downloaded file(s) already here, nothing to save") }
            return (inVault, 0)
        }

        var stored: [String] = []
        switch plan {
        case .none:
            for file in toStore where await importToOwnVaultInProcess(source: .file(file.url), sha256: file.sha256, contentType: file.contentType) {
                stored.append(file.sha256)
            }
        case .batch:
            for batch in AutoMirrorSigning.batches(toStore) {
                guard let auth = await makeBatchUploadAuth(hashes: batch.map(\.sha256)) else {
                    appLog("Auto-Mirror: the signer gave no authorisation for \(batch.count) file(s); left for the next run", level: "WARN")
                    continue
                }
                for file in batch where await uploadToLocalWithRecovery(source: .file(file.url), sha256: file.sha256,
                                                                       contentType: file.contentType, authBase64: auth) != nil {
                    stored.append(file.sha256)
                }
            }
        }
        for sha in stored {
            await stampCopiedIn(sha256: sha, date: dates[sha.lowercased()])
            inVault.insert(sha.lowercased())
        }
        if !stored.isEmpty { await announceStoredInVault() }
        appLog("Auto-Mirror: saved \(stored.count) of \(toStore.count) new file(s), \(files.count - toStore.count) already here (\(plan == .none ? "no signer" : "batch signed"))")
        return (inVault, stored.count)
    }
}
