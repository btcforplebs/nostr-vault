import Foundation
import Combine
import SwiftUI

extension NostrService {
    /// `older`: Load older, each Vault stream from its own cursor
    /// (VaultFetchFilters.olderCursors); nil reads the newest window.
    func fetchNotes(from relayURLs: [URL], older: [VaultFetchFilters.Stream: Int64]? = nil, since: Int64? = nil, authors: [String]? = nil) {
        // Count only the subscriptions we actually open/request below — NOT every
        // URL passed in. Skipped URLs (local relay not ready, already connecting,
        // reconnecting, or backing off) never deliver an EOSE, so pre-counting
        // them with `relayURLs.count` left `activeSubscriptionCount` stuck above 0
        // and wedged `isFetching` true forever — the "Loading notes…" overlay that
        // hangs after an account switch. `awaiting` is tallied as we go and the
        // fetch state is committed once, after the loop.
        var awaiting = 0
        for url in relayURLs {
            let urlString = url.absoluteString

            // Skip local relay if it's still booting - prevents connection spam during boot
            // This guard is critical: prevents 10-second timeout freezes during relay boot
            if isLocalRelay(url) && !isLocalRelayReady {
                #if DEBUG
                if shouldLogConnect() {
                    print("NostrService: Skipping local relay - RelayProcessManager not ready (isRunning=\(RelayProcessManager.shared.isRunning), isBooting=\(RelayProcessManager.shared.isBooting))")
                }
                #endif
                continue
            }

            if let existing = clients[urlString] {
                if existing.connectionState == .connected {
                    sendRequest(to: existing, url: url, older: older, since: since, authors: authors)
                    awaiting += 1
                    continue
                } else if existing.connectionState == .connecting {
                    // Its own connectionState sink will send the request once
                    // connected and produce an EOSE — don't double-count it here.
                    continue
                }
            }

            // Prevent concurrent reconnection attempts for the same URL
            if relaysReconnecting.contains(urlString) {
                #if DEBUG
                print("NostrService: Skipping \(urlString) - reconnection already in progress")
                #endif
                continue
            }

            // Check if we should delay reconnect (exponential backoff)
            if let lastAttempt = relayLastReconnectTime[urlString],
               let attempts = relayReconnectAttempts[urlString] {
                let delay = delayWithJitter(attempts: attempts)
                let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)

                if timeSinceLastAttempt < delay {
                    #if DEBUG
                    print("NostrService: Skipping reconnect to \(urlString) - backing off (\(attempts) attempts, \(delay - timeSinceLastAttempt)s remaining)")
                    #endif
                    // Schedule retry after backoff delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + (delay - timeSinceLastAttempt)) { [weak self] in
                        guard let self = self else { return }
                        guard self.clients[urlString] != nil else { return }
                        self.fetchNotes(from: [url], older: older, since: since, authors: authors)
                    }
                    continue
                }
            }

            relaysReconnecting.insert(urlString)

            // Close old subscription explicitly before creating a new client
            if let oldSubId = activeSubscriptions[urlString] {
                if let oldClient = clients[urlString] {
                    let closeMsg = ["CLOSE", oldSubId] as [Any]
                    if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                       let closeStr = String(data: closeData, encoding: .utf8) {
                        oldClient.send(text: closeStr)
                    }
                }
                activeSubscriptions.removeValue(forKey: urlString)
            }

            // Disconnect old client before replacing
            clients[urlString]?.disconnect()

            let client = WebSocketClient()
            clients[urlString] = client

            client.messageSubject
                .receive(on: processingQueue)
                .sink { [weak self] message in
                    self?.processMessage(message, from: urlString)
                }
                .store(in: &cancellables)

            client.$connectionState
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak client] state in
                    guard let self = self else { return }
                    self.updateAggregatedStatus()
                    if state == .connected {
                        // The backoff resets when this connection drops after
                        // staying up long enough (stableConnectionTime), not here.
                        self.relayConnectedAt[urlString] = Date()
                        self.relaysReconnecting.remove(urlString)
                        self.sendRequest(to: client!, url: url, older: older, since: since, authors: authors)
                    } else if state == .error {
                        self.relaysReconnecting.remove(urlString)

                        if let openedAt = self.relayConnectedAt.removeValue(forKey: urlString),
                           Date().timeIntervalSince(openedAt) >= self.stableConnectionTime {
                            self.relayReconnectAttempts[urlString] = 0
                        }
                        // Increment backoff counter
                        let attempts = (self.relayReconnectAttempts[urlString] ?? 0) + 1
                        self.relayReconnectAttempts[urlString] = attempts
                        self.relayLastReconnectTime[urlString] = Date()

                        // Check if we've exceeded max attempts - stop hammering
                        if attempts > self.maxReconnectAttempts {
                            #if DEBUG
                            print("NostrService: Max reconnect attempts reached for \(urlString), giving up")
                            #endif
                            // This subscription will never EOSE — release its slot
                            // so a dead relay can't hold `isFetching` true.
                            self.activeSubscriptionCount -= 1
                            if self.activeSubscriptionCount <= 0 {
                                self.isFetching = false
                                self.activeSubscriptionCount = 0
                                self.cancelFetchWatchdog()
                            }
                            return
                        }

                        // Calculate exponential backoff delay with jitter
                        let delay = self.delayWithJitter(attempts: attempts - 1)

                        #if DEBUG
                        print("NostrService: Reconnecting to \(urlString) in \(delay)s (attempt \(attempts)/\(self.maxReconnectAttempts))")
                        #endif

                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self else { return }
                            guard self.clients[urlString] != nil else { return }
                            self.fetchNotes(from: [url], older: older, since: since, authors: authors)
                        }
                    }
                }
                .store(in: &cancellables)

            client.connect(url: url)
            awaiting += 1
        }

        // Commit fetch state once, now that we know how many subscriptions will
        // actually report EOSE, and arm the watchdog. If nothing was opened
        // (awaiting == 0) there is nothing to wait for — don't latch isFetching.
        isFetching = awaiting > 0
        activeSubscriptionCount = awaiting
        if awaiting > 0 {
            armFetchWatchdog()
        } else {
            cancelFetchWatchdog()
        }
    }

    /// Arms (or re-arms) the fetch watchdog. If `isFetching` is still true after
    /// the timeout — some subscription never delivered EOSE (unreachable relay or
    /// a socket torn down mid-fetch) — force it off so the Viewer/Relay
    /// "Loading notes…" overlay can never hang. Cancelled on real completion.
    private func armFetchWatchdog() {
        fetchWatchdogTask?.cancel()
        fetchWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s safety net
            guard let self = self, !Task.isCancelled, self.isFetching else { return }
            #if DEBUG
            print("NostrService: fetch watchdog fired — forcing isFetching=false (\(self.activeSubscriptionCount) subscription(s) never EOSE'd)")
            #endif
            self.flushEventBuffer()
            self.activeSubscriptionCount = 0
            self.isFetching = false
            self.eventUpdateSubject.send()
        }
    }

    func cancelFetchWatchdog() {
        fetchWatchdogTask?.cancel()
        fetchWatchdogTask = nil
    }


    private func sendRequest(to client: WebSocketClient, url: URL, older: [VaultFetchFilters.Stream: Int64]? = nil, since: Int64? = nil, authors: [String]? = nil) {
        let urlString = url.absoluteString
        let isHistorical = older != nil

        let context = url.lastPathComponent.isEmpty ? "root" : url.lastPathComponent
        let subscriptionId: String

        if isHistorical {
            // Unique ID for pagination
            subscriptionId = "viewer-\(context)-hist-\(UUID().uuidString.prefix(4))"
        } else {
            // Stable ID for live feed
            subscriptionId = "viewer-\(context)-live"

            // Close previous live subscription if it's different (shouldn't happen with stable names, but safer)
            if let oldId = activeSubscriptions[urlString], oldId != subscriptionId {
                let closeMsg = ["CLOSE", oldId] as [Any]
                if let closeData = try? JSONSerialization.data(withJSONObject: closeMsg),
                   let closeStr = String(data: closeData, encoding: .utf8) {
                    client.send(text: closeStr)
                }
            }
            activeSubscriptions[urlString] = subscriptionId
        }

        let filters = older.map {
            VaultFetchFilters.olderFilters(ownerHex: self.activeHexPubkey, authors: authors,
                                           noteKinds: Self.relayTabNoteKinds, cursors: $0)
        } ?? Self.vaultFilters(ownerHex: self.activeHexPubkey, authors: authors, since: since)

        let req = ["REQ", subscriptionId] + filters
        if let reqData = try? JSONSerialization.data(withJSONObject: req),
           let reqString = String(data: reqData, encoding: .utf8) {
            #if DEBUG
            print("NostrService: Sending REQ (\(subscriptionId)) with \(filters.count) filters to \(url.absoluteString)")
            #endif
            client.send(text: reqString)
        }
    }

    /// The Vault's read: the socket REQ and the direct store read
    /// (NostrService+VaultDirectRead) ask the same filters (VaultFetchFilters).
    static func vaultFilters(ownerHex: String, authors: [String]?, since: Int64?) -> [[String: Any]] {
        VaultFetchFilters.filters(ownerHex: ownerHex, authors: authors, since: since,
                                  noteKinds: relayTabNoteKinds)
    }
}
