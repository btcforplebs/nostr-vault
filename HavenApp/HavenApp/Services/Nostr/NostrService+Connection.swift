import Foundation
import Combine
import SwiftUI

extension NostrService {
    func shouldLogConnect() -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastConnectLog) > 5.0 {
            lastConnectLog = now
            return true
        }
        return false
    }

    func fetchRelayList(for pubkey: String) {
        guard (relayLists[pubkey] == nil || dmRelayLists[pubkey] == nil) && !relaysInFlight.contains(pubkey) else { return }
        relaysInFlight.insert(pubkey)

        // Looking things up is reading: the Read relays
        var relays = ConfigService.shared.config.readRelays

        // Include cached outbox (write) relays for this user — their kind 10002/10050
        // is most likely to be found on their own write relays.
        if let cachedOutbox = outboxRelays[pubkey] {
            for relay in cachedOutbox where !relays.contains(relay) {
                relays.append(relay)
            }
        }

        #if DEBUG
        print("NostrService: Fetching relay list (10002/10050) for \(pubkey.prefix(8))...")
        #endif

        let uniqueRelays = Array(Set(relays)).compactMap { URL(string: $0) }

        // Safety net: clear the in-flight guard 10s after the attempt starts
        // regardless of outcome, so a failed fetch can be retried later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.relaysInFlight.remove(pubkey)
        }

        for url in uniqueRelays {
            let client = WebSocketClient()
            client.isTemporary = true

            let urlString = url.absoluteString
            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { state in
                    if state == .connected {
                        let subscriptionId = "relays-\(UUID().uuidString.prefix(8))"
                        let filter: [String: Any] = [
                            "kinds": [10002, 10050],
                            "authors": [pubkey],
                            "limit": 2
                        ]

                        let req = ["REQ", subscriptionId, filter] as [Any]
                        if let reqData = try? JSONSerialization.data(withJSONObject: req),
                           let reqString = String(data: reqData, encoding: .utf8) {
                            client.send(text: reqString)
                        }

                        // Disconnect after reasonable timeout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            client.disconnect()
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            trackTemporaryClient(client)
        }
    }

    /// Registers a temporary client in `temporaryClients` and arranges
    /// for it to be removed when it disconnects or errors out.
    func trackTemporaryClient(_ client: WebSocketClient) {
        temporaryClients.insert(client)
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self = self, let client = client else { return }
                if state == .disconnected || state == .error {
                    self.temporaryClients.remove(client)
                }
            }
            .store(in: &cancellables)
    }

    func resetConnections() {
        for (urlString, subId) in activeSubscriptions {
            if let client = clients[urlString] {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
        }
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        relaysReconnecting.removeAll()
        // Disconnect temporary clients BEFORE clearing cancellables so their
        // ping timers are cancelled via the normal disconnectLocked() path.
        for client in temporaryClients { client.disconnect() }
        temporaryClients.removeAll()
        closeProfileLookupSockets()
        cancellables.removeAll()
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()
        setupThrottling()
    }

    /// Resets all WebSocket state when the active account changes.
    /// Unlike resetConnections(), this preserves the config observer and
    /// also clears per-account event/media state (Viewer tab).
    func handleAccountSwitch() {
        // 1. Send CLOSE for all active relay subscriptions, then disconnect
        for (urlString, subId) in activeSubscriptions {
            if let client = clients[urlString] {
                let closeMsg = ["CLOSE", subId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
        }
        for client in clients.values {
            client.disconnect()
        }
        clients.removeAll()
        activeSubscriptions.removeAll()
        relaysReconnecting.removeAll()

        // Disconnect temporary clients BEFORE clearing cancellables so their
        // ping timers are cancelled via the normal disconnectLocked() path.
        for client in temporaryClients { client.disconnect() }
        temporaryClients.removeAll()
        closeProfileLookupSockets()

        // Cancel stale connection-state sinks from the previous account's
        // WebSocket clients. Without this, orphaned sinks fire
        // updateAggregatedStatus() with dead clients and can trigger phantom
        // reconnection attempts for URLs that no longer exist.
        cancellables.removeAll()
        setupThrottling()

        // 2. Clear Viewer tab event state — these belong to the previous account
        events.removeAll()
        eventsResetGeneration += 1
        noteMedia.removeAll()
        clearSeen()

        // 3. Flush pending event buffer
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
        bufferLock.lock()
        eventBuffer.removeAll()
        bufferLock.unlock()

        // 4. Reset fetch/subscription tracking
        isFetching = false
        activeSubscriptionCount = 0
        cancelFetchWatchdog()

        // 5. Clear reconnect backoff state
        relayReconnectAttempts.removeAll()
        relayLastReconnectTime.removeAll()

        // 6. Notify UI of cleared state
        eventUpdateSubject.send()

        // 7. Update identity and prefetch avatars for the new account
        updateOwnerHex()
        prefetchWhitelistedProfiles()

        // 8. Re-establish relay connections for the new account.
        // Previously this step was missing — the teardown above left the
        // Viewer tab with zero WebSocket clients, so the relay indicator
        // went yellow → red and the feed stayed empty until pull-to-refresh.
        reconnectForActiveAccount()

        #if DEBUG
        print("NostrService: Account switch — reset connections and reconnected for new account")
        #endif
    }

    /// Builds relay URLs and author filters from the current config and
    /// opens fresh WebSocket connections for the Viewer tab.
    private func reconnectForActiveAccount() {
        let config = ConfigService.shared.config

        var urls = [config.nostrURL, config.nostrURL + "/inbox"]
            .compactMap { URL(string: $0) }

        let macURL = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !macURL.isEmpty {
            if let macRelay = URL(string: macURL) { urls.append(macRelay) }
            if let macInbox = URL(string: macURL + "/inbox") { urls.append(macInbox) }
        }

        guard !urls.isEmpty else { return }

        var authorsSet = Set<String>()
        if !ownerHexPubkey.isEmpty {
            authorsSet.insert(ownerHexPubkey)
        }
        for pk in ConfigService.shared.whitelistedHexPubkeys {
            authorsSet.insert(pk)
        }

        fetchNotes(from: urls, authors: Array(authorsSet))
    }

    func setupThrottling() {
        // Debounce UI updates to prevent main thread saturation and fix NSStatusItem threading crash
        eventUpdateSubject
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// Adds 0-2s random jitter to prevent all clients reconnecting simultaneously after a network drop
    func delayWithJitter(attempts: Int) -> TimeInterval {
        let base = min(baseReconnectDelay * pow(2.0, Double(attempts)), maxReconnectDelay)
        let jitter = Double.random(in: 0...2.0)
        return base + jitter
    }

    // Check if URL is the local relay
    func isLocalRelay(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? 80
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" ||
               (host == "127.0.0.1" && port == 3355) ||
               (host == "localhost" && port == 3355)
    }

    // Check if local relay is ready (not booting)
    var isLocalRelayReady: Bool {
        // Check if relay manager says it's running AND not booting
        return RelayProcessManager.shared.isRunning && !RelayProcessManager.shared.isBooting
    }


    func updateAggregatedStatus() {
        let states = clients.values.map { $0.connectionState }
        if states.contains(.connected) {
            // Upgrading to green is immediate; cancel any pending downgrade
            statusDowngradeTask?.cancel()
            statusDowngradeTask = nil
            connectionStatus = "Connected"
            connectionColor = "green"
        } else {
            // Downgrade from green is debounced to avoid flicker during brief reconnects
            let wasGreen = connectionColor == "green"
            let newStatus: String
            let newColor: String
            if states.contains(.connecting) {
                newStatus = "Connecting..."
                newColor = "yellow"
            } else if states.contains(.error) {
                newStatus = "Connection Error"
                newColor = "red"
            } else {
                newStatus = "Disconnected"
                newColor = "gray"
            }

            if wasGreen && newColor == "yellow" {
                // Debounce: wait before showing yellow so brief reconnects don't flicker
                if statusDowngradeTask == nil {
                    statusDowngradeTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        guard !Task.isCancelled else { return }
                        // Re-check state after delay
                        let currentStates = self.clients.values.map { $0.connectionState }
                        if !currentStates.contains(.connected) {
                            self.connectionStatus = newStatus
                            self.connectionColor = newColor
                        }
                        self.statusDowngradeTask = nil
                    }
                }
            } else {
                statusDowngradeTask?.cancel()
                statusDowngradeTask = nil
                connectionStatus = newStatus
                connectionColor = newColor
            }
        }
    }
}
