import SwiftUI

extension VaultView {

    // MARK: - Networking

    func refreshAll() {
        // Only proceed if relay is actually ready
        guard relayManager.isRunning && !relayManager.isBooting else {
            #if DEBUG
            print("VaultView: Skipping refresh - relay not ready")
            #endif
            return
        }

        // Debounce: cancel any pending refresh and wait 0.5s before executing.
        // Multiple rapid lifecycle events (onAppear, onChange isBooting, onChange isRunning)
        // can fire within milliseconds of each other — this coalesces them into one refresh.
        refreshDebounceTask?.cancel()
        refreshDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            guard !Task.isCancelled else { return }
            performRefresh()
        }
    }

    func performRefresh() {
        // Ask the embedded relay to fetch newly tagged events (replies, reactions,
        // zaps, reposts, mentions, DMs) and the owner's own notes from external
        // relays into the local DBs. Injected events stream in over the local
        // /inbox subscription opened by fetchNotes below. Non-blocking; no-op-safe
        // if the relay isn't running.
        RequestRelaySyncC()

        nostrService.resetConnections()
        // Use the centralized nostrURL which handles local vs remote correctly
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }

        // Also query the Mac relay for tagged notes the local relay may
        // not have (e.g. due to shorter WoT depth or notes missed while suspended).
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty {
            if let macRelay = URL(string: macURL) { urls.append(macRelay) }
            if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
        }

        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)

        nostrService.fetchNotes(from: urls, authors: authors)
    }

    /// Fetch notes referenced by the owner's likes that aren't already in the events array.
    func fetchMissingLikedNotes() {
        let owner = nostrService.activeHexPubkey
        guard !owner.isEmpty else { return }

        let likedNoteIds = Set(nostrService.events.filter { $0.kind == 7 && $0.pubkey == owner }.compactMap { event in
            event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        })
        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(likedNoteIds.subtracting(existingIds).subtracting(requestedMissingIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingIds.insert(id) }

        #if DEBUG
        print("VaultView: Fetching \(missingIds.count) missing liked notes")
        #endif

        var urls = [configService.config.nostrURL].compactMap { URL(string: $0) }
        // Also try external relays for notes not on the local relay
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    /// Fetch a larger set of zap receipts from the relay when entering zaps mode.
    func fetchMoreZapReceipts() {
        guard !hasFetchedZapReceipts else { return }
        hasFetchedZapReceipts = true

        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macRelay = URL(string: macURL) {
            urls.append(macRelay)
        }

        #if DEBUG
        print("VaultView: Fetching extended zap receipts history")
        #endif
        nostrService.fetchZapReceipts(from: urls, limit: 1000)
    }

    /// Fetch notes referenced by zap receipts that aren't already in the events array.
    func fetchMissingZappedNotes() {
        let zapReceipts = nostrService.events.filter { $0.kind == 9735 }
        guard !zapReceipts.isEmpty else { return }

        var targetNoteIds = Set<String>()
        for receipt in zapReceipts {
            if let cached = zapReceiptCache[receipt.id] {
                if let noteId = cached.targetNoteId { targetNoteIds.insert(noteId) }
            } else if let targetId = receipt.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1] {
                targetNoteIds.insert(targetId)
            }
        }

        let existingIds = Set(nostrService.events.map { $0.id })
        let missingIds = Array(targetNoteIds.subtracting(existingIds).subtracting(requestedMissingZapNoteIds))

        guard !missingIds.isEmpty else { return }
        for id in missingIds { requestedMissingZapNoteIds.insert(id) }

        #if DEBUG
        print("VaultView: Fetching \(missingIds.count) missing zapped notes")
        #endif

        var urls = [configService.config.nostrURL].compactMap { URL(string: $0) }
        let externalStrs = configService.config.activeFeedRelays.isEmpty ? [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
        ] : configService.config.activeFeedRelays
        urls.append(contentsOf: externalStrs.compactMap { URL(string: $0) })

        nostrService.fetchNotesByIds(missingIds, from: urls)
    }

    func loadMoreItems() {
        let totalCount: Int
        switch viewMode {
        case .notes, .media: totalCount = nostrService.events.count
        case .likes: totalCount = nostrService.events.count
        case .zaps: totalCount = nostrService.events.count
        }
        if maxDisplayedItems < totalCount {
            maxDisplayedItems += 50
            scheduleUpdateDisplayData()
        }
    }

    func loadMore() {
        guard !nostrService.isFetching else { return }

        // Get the oldest timestamp from events
        guard let oldestTimestamp = nostrService.events.last?.created_at else { return }

        // Request events strictly older than the last one we have
        #if DEBUG
        print("VaultView: Requesting older events until: \(oldestTimestamp - 1)")
        #endif
        var urls = [configService.config.nostrURL, configService.config.nostrURL + "/inbox"].compactMap { URL(string: $0) }
        guard !urls.isEmpty else { return }
        let macURL = configService.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty, let macInbox = URL(string: macURL + "/inbox") {
            urls.append(macInbox)
        }

        var authorsSet = Set<String>()
        if let ownerHex = Bech32.decode(configService.config.ownerNpub)?.hexString {
            authorsSet.insert(ownerHex)
        }
        for pk in configService.whitelistedHexPubkeys { authorsSet.insert(pk) }
        let authors = Array(authorsSet)

        nostrService.fetchNotes(from: urls, until: oldestTimestamp - 1, authors: authors)
    }
}
