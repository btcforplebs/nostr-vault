import Foundation

/// The Vault's rows straight from the on-device store (Logen 2026-11-14):
/// the engine runs in this process, so the read asks it directly
/// (QueryVaultC) instead of over the local relay socket. No port, TLS or log
/// line to wait for: a return or an account switch reads in tens of ms even
/// while iOS has the relay port closed. Live updates, and the Mac relay a
/// phone may read, stay on the socket.
///
/// The events go through the same path as the socket's (processEvent), so
/// the Vault lists, the news dot, the media viewer and the live list all read
/// them as before. When the store isn't ready (engine starting, import, a
/// stop) nothing happens here and the socket reads as it always did.
extension NostrService {
    /// Reads the active account's Vault events from the store. The first read
    /// for an account takes the whole window, later ones what's new. One at a
    /// time; a call during a read runs once more after it.
    func readVaultFromStore() {
        let owner = activeHexPubkey.lowercased()
        guard !owner.isEmpty else { return }
        if vaultStoreReading {
            vaultStoreReadAgain = true
            return
        }
        vaultStoreReading = true
        let since = VaultDirectRead.storeSince(answeredBefore: vaultStoreAnswered == owner,
                                               newest: events.map(\.created_at).max(),
                                               now: Int64(Date().timeIntervalSince1970))
        let authors = VaultView.activitySources(ConfigService.shared).authors
        let filters = Self.vaultFilters(ownerHex: owner, authors: authors, until: nil, since: since)
        // Local, so processEvent never injects these back into the relay.
        let local = ConfigService.shared.config.nostrURL
        let generation = eventsResetGeneration

        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = Self.queryVaultStore(filters: filters)
            guard let self else { return }
            guard let rows else {
                await MainActor.run { self.vaultStoreReadDone(account: nil) }
                return
            }
            // The socket's queue: the same ordering and threading as its events.
            self.processingQueue.async { [weak self] in
                guard let self else { return }
                for row in rows { self.processEvent(row, from: local) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // A switch meanwhile: these were the old account's.
                    let current = generation == self.eventsResetGeneration && self.activeHexPubkey.lowercased() == owner
                    self.flushEventBuffer()
                    self.events.sort(by: { $0.created_at > $1.created_at })
                    self.vaultStoreReadDone(account: current ? owner : nil)
                    self.eventUpdateSubject.send()
                    if current, rows.isEmpty == false { RelayProcessManager.shared.startupMark("vault store read \(rows.count)") }
                }
            }
        }
    }

    private func vaultStoreReadDone(account: String?) {
        if let account { vaultStoreAnswered = account }
        vaultStoreReading = false
        if vaultStoreReadAgain {
            vaultStoreReadAgain = false
            readVaultFromStore()
        }
    }

    /// The engine's answer as event dictionaries, newest first; nil when the
    /// store can't answer now (the caller's socket read covers it).
    nonisolated static func queryVaultStore(filters: [[String: Any]]) -> [[String: Any]]? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["filters": filters]),
              let request = String(data: body, encoding: .utf8) else { return nil }
        guard let ptr = request.withCString({ QueryVaultC(UnsafeMutablePointer(mutating: $0)) }) else { return nil }
        defer { free(ptr) }
        let answer = Data(bytes: ptr, count: strlen(ptr))
        return VaultStoreAnswer.rows(answer)
    }

    /// Deletes the saved Vault screens of earlier builds, off the main thread.
    nonisolated static func removeOldVaultSnapshots() {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("vault-snapshots", isDirectory: true) else { return }
        DispatchQueue.global(qos: .utility).async {
            if FileManager.default.fileExists(atPath: folder.path) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
