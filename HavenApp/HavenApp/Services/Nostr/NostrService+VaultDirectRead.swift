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
    /// Reads the active account's Vault events from the store: the whole
    /// window every time (VaultDirectRead.storeRead), so a note stored late
    /// shows too. One at a time; a call during a read runs once more after
    /// it.
    func readVaultFromStore() {
        let owner = activeHexPubkey.lowercased()
        guard !owner.isEmpty else { return }
        if vaultStoreReading {
            vaultStoreReadAgain = true
            return
        }
        vaultStoreReading = true
        let authors = VaultView.activitySources(ConfigService.shared).authors
        let filters = Self.vaultFilters(ownerHex: owner, authors: authors, until: nil, since: nil)
        let passes = VaultDirectRead.storeRead(filters, answeredBefore: vaultStoreAnswered == owner)
        // Local, so processEvent never injects these back into the relay.
        let local = ConfigService.shared.config.nostrURL
        let generation = eventsResetGeneration
        if vaultStoreAnswered != owner { RelayProcessManager.shared.startupMark("vault store asked") }

        Task.detached(priority: .userInitiated) { [weak self] in
            // Not ready while the engine starts: ask again every 20 ms rather
            // than wait for the "ready" log line (VaultDirectRead.retriesNotReady).
            let asked = Date()
            var rows = Self.queryVaultStore(filters: passes.first)
            while rows == nil {
                let booting = await MainActor.run { RelayProcessManager.shared.state == .booting }
                guard VaultDirectRead.retriesNotReady(booting: booting, waited: Date().timeIntervalSince(asked)) else { break }
                try? await Task.sleep(nanoseconds: VaultDirectRead.notReadyRetry)
                rows = Self.queryVaultStore(filters: passes.first)
            }
            if let rows, rows.isEmpty == false { RelayProcessManager.startupMarkOffMain("vault store answered \(rows.count)") }
            guard let self else { return }
            guard let rows else {
                await MainActor.run { self.vaultStoreReadDone(account: nil) }
                return
            }
            await self.takeStoreRows(rows, owner: owner, generation: generation, from: local) { current in
                self.vaultStoreReadDone(account: current ? owner : nil)
                if current, rows.isEmpty == false { RelayProcessManager.shared.startupMark("vault store read \(rows.count)") }
                // The follower lists after the rows are up; they don't hold
                // the list (the read is done), and a miss here leaves them to
                // the socket as before.
                guard current, !passes.after.isEmpty else { return }
                Task.detached(priority: .utility) { [weak self] in
                    guard let lists = Self.queryVaultStore(filters: passes.after), !lists.isEmpty, let self else { return }
                    await self.takeStoreRows(lists, owner: owner, generation: generation, from: local) { current in
                        if current { RelayProcessManager.shared.startupMark("vault store lists \(lists.count)") }
                    }
                }
            }
        }
    }

    /// Store rows through the socket's path (processingQueue, processEvent),
    /// then published on main; done gets whether they still belong to the
    /// active account (a switch meanwhile: they were the old account's).
    private func takeStoreRows(_ rows: [[String: Any]], owner: String, generation: Int, from local: String,
                               done: @escaping @MainActor (Bool) -> Void) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            for row in rows { self.processEvent(row, from: local) }
            if rows.isEmpty == false { RelayProcessManager.startupMarkOffMain("vault store rows taken \(rows.count)") }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let current = generation == self.eventsResetGeneration && self.activeHexPubkey.lowercased() == owner
                self.flushEventBuffer()
                self.events.sort(by: { $0.created_at > $1.created_at })
                done(current)
                self.eventUpdateSubject.send()
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
        RelayProcessManager.startupMarkOffMain("vault store bytes \(answer.count / 1024) KB")
        return VaultStoreAnswer.rows(answer)
    }

    /// One filter's events from the store, read and decoded off the main
    /// thread: another account's lines for the Vault chips. Nil when the
    /// store can't answer now (the caller reads over the socket instead).
    nonisolated static func storeEvents(filter: [String: Any]) async -> [NostrEvent]? {
        await Task.detached(priority: .userInitiated) { () -> [NostrEvent]? in
            guard let body = try? JSONSerialization.data(withJSONObject: ["filters": [filter]]),
                  let request = String(data: body, encoding: .utf8) else { return nil }
            guard let ptr = request.withCString({ QueryVaultC(UnsafeMutablePointer(mutating: $0)) }) else { return nil }
            defer { free(ptr) }
            return VaultStoreAnswer.events(Data(bytes: ptr, count: strlen(ptr)), as: NostrEvent.self)
        }.value
    }

    /// The Vault chips' read: the store when it can answer, else the
    /// device's relay over the socket as before.
    func vaultAccountEvents(filter: [String: Any], from relays: [String]) async -> [NostrEvent] {
        if let events = await Self.storeEvents(filter: filter) { return events }
        return await fetchEvents(filter: filter, from: relays, includeLoopback: true)
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
