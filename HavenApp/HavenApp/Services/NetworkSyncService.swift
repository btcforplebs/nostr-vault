#if os(macOS)
import Foundation
import Combine
import os.log

/// Maintains persistent WebSocket subscriptions to external relays for the
/// owner and all whitelisted accounts.  Events are injected into the local
/// relay in real-time as they arrive, rather than on a polling interval.
///
/// On start: sends REQ since lastSyncTimestamp (catchup), keeps subscription
/// open for live events.  Reconnects with backoff on disconnect.
@MainActor
class NetworkSyncService {
    static let shared = NetworkSyncService()
    private init() {}

    private let logger = Logger(subsystem: "com.bitvora.haven", category: "network-sync")
    private let processingQueue = DispatchQueue(label: "com.haven.network-sync", qos: .utility)
    private let lastSyncKey = "com.haven.networkSync.lastSyncTimestamp"

    private var clients: [String: WebSocketClient] = [:]
    private var cancellables: [String: Set<AnyCancellable>] = [:]
    private var reconnectWork: [String: DispatchWorkItem] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private var isStarted = false

    /// Tracks event IDs already injected into the local relay to prevent
    /// feedback loops (event blasted → received back → re-injected → re-blasted).
    private var injectedEventIds = Set<String>()
    private let maxInjectedIds = 10_000

    /// Events waiting for an injection client that is still connecting.
    /// Without this, each event in a burst replaced the connecting client
    /// (dropping the previous event and dialing a fresh socket per event).
    private var pendingInjections: [String: [[String: Any]]] = [:]
    private let maxPendingInjections = 1_000

    var lastSyncTimestamp: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: lastSyncKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSyncKey) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectAll()
        logger.info("NetworkSyncService started")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        reconnectWork.values.forEach { $0.cancel() }
        reconnectWork.removeAll()
        reconnectAttempts.removeAll()
        clients.values.forEach { $0.disconnect() }
        clients.removeAll()
        cancellables.removeAll()
        injectedEventIds.removeAll()
        pendingInjections.removeAll()
        logger.info("NetworkSyncService stopped")
    }

    func reload() {
        guard isStarted else { return }
        stop()
        isStarted = true
        connectAll()
    }

    // MARK: - Connection

    private func connectAll() {
        let config = ConfigService.shared.config
        let relayStrings = Array(Set(config.activeFeedRelays + config.activeImportSeedRelays))
        for urlStr in relayStrings {
            guard URL(string: urlStr) != nil else { continue }
            connect(to: urlStr)
        }
    }

    private func connect(to urlStr: String) {
        guard isStarted, let url = URL(string: urlStr) else { return }

        clients[urlStr]?.disconnect()
        var subs = Set<AnyCancellable>()

        let client = WebSocketClient()
        client.isTemporary = false
        clients[urlStr] = client

        client.messageSubject
            .receive(on: processingQueue)
            .sink { [weak self] message in
                self?.handleMessage(message, relay: urlStr)
            }
            .store(in: &subs)

        var sawConnecting = false
        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, self.isStarted else { return }
                // Only the current client for this relay may drive reconnects;
                // a replaced client's teardown must not redial its successor.
                guard let client, self.clients[urlStr] === client else { return }
                switch state {
                case .connecting:
                    sawConnecting = true
                case .connected:
                    self.reconnectAttempts[urlStr] = 0
                    // A reconnect scheduled during setup would tear down this
                    // healthy connection when it fires — kill it.
                    self.reconnectWork[urlStr]?.cancel()
                    self.reconnectWork[urlStr] = nil
                    self.sendSubscription(to: client, relay: urlStr)
                case .disconnected, .error:
                    // @Published replays the initial .disconnected the moment
                    // the sink subscribes, and connect() emits another during
                    // its setup teardown. Treating those as failures made
                    // every successful connect schedule a redial against
                    // itself — a perpetual ~2s dial/teardown cycle per relay.
                    // Only a drop after a real connection attempt counts.
                    guard sawConnecting else { return }
                    sawConnecting = false
                    self.scheduleReconnect(to: urlStr)
                }
            }
            .store(in: &subs)

        cancellables[urlStr] = subs
        client.connect(url: url)
    }

    private func sendSubscription(to client: WebSocketClient, relay: String) {
        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        let whitelistedHex = Array(ConfigService.shared.whitelistedHexPubkeys)
        let authors = ([ownerHex] + whitelistedHex).filter { !$0.isEmpty }
        guard !authors.isEmpty else { return }

        let since = max(0, lastSyncTimestamp - 3600)
        var filter: [String: Any] = ["authors": authors, "limit": 5000]
        if since > 0 { filter["since"] = since }

        let subId = "net-sync"
        let req: [Any] = ["REQ", subId, filter]
        if let data = try? JSONSerialization.data(withJSONObject: req),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
            logger.debug("NetworkSyncService: subscribed on \(relay) since \(since)")
        }
    }

    private func scheduleReconnect(to urlStr: String) {
        guard isStarted else { return }
        reconnectWork[urlStr]?.cancel()

        let attempts = reconnectAttempts[urlStr] ?? 0
        let delay = min(pow(2.0, Double(attempts)), 120.0) // cap at 2 min
        reconnectAttempts[urlStr] = attempts + 1

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // The connection may have recovered while this was queued.
            if let current = self.clients[urlStr], current.connectionState == .connected { return }
            self.connect(to: urlStr)
        }
        reconnectWork[urlStr] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        logger.debug("NetworkSyncService: reconnecting to \(urlStr) in \(delay)s")
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: String, relay: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json[0] as? String else { return }

        if type == "EOSE" {
            // Catchup done — update timestamp so reconnects only fetch newer events
            let now = Int64(Date().timeIntervalSince1970)
            DispatchQueue.main.async { self.lastSyncTimestamp = now }
            return
        }

        guard type == "EVENT", json.count >= 3,
              let eventDict = json[2] as? [String: Any] else { return }

        DispatchQueue.main.async {
            self.injectEvent(eventDict)
        }
    }

    // MARK: - Inject

    private func injectEvent(_ eventDict: [String: Any]) {
        // Skip injection when FeedService is actively injecting — avoids duplicate writes
        guard !FeedService.shared.isInjecting else { return }

        // Dedup: skip events we've already injected to prevent blast feedback loops
        if let eventId = eventDict["id"] as? String {
            if injectedEventIds.contains(eventId) { return }
            injectedEventIds.insert(eventId)
            // Prevent unbounded growth — clear and let it rebuild naturally
            if injectedEventIds.count > maxInjectedIds {
                injectedEventIds.removeAll(keepingCapacity: true)
                injectedEventIds.insert(eventId)
            }
        }

        let config = ConfigService.shared.config
        let ownerHex = Bech32.decode(config.ownerNpub)?.hexString ?? ""
        let whitelisted = ConfigService.shared.whitelistedHexPubkeys

        let isAuthoredByTracked: Bool
        if let pubkey = eventDict["pubkey"] as? String {
            isAuthoredByTracked = pubkey == ownerHex || whitelisted.contains(pubkey)
        } else {
            isAuthoredByTracked = false
        }

        let targetURL = isAuthoredByTracked
            ? config.nostrURL
            : config.nostrURL + "/inbox"

        // The outbox address is marked as pulled: the relay stores these and
        // never blasts them back to the relays they came from (PulledInjection).
        // /inbox has no blast either way.
        guard let url = isAuthoredByTracked ? PulledInjection.url(targetURL) : URL(string: targetURL) else { return }

        // Reuse an existing injection client when possible: send immediately
        // if connected, queue if still connecting. Only a dead client
        // (.disconnected/.error) gets replaced.
        let key = "__inject__\(targetURL)"
        if let existing = clients[key] {
            switch existing.connectionState {
            case .connected:
                sendInjection(eventDict, via: existing)
                return
            case .connecting:
                enqueueInjection(eventDict, for: key)
                return
            case .disconnected, .error:
                break
            }
        }

        enqueueInjection(eventDict, for: key)

        let client = WebSocketClient()
        client.isTemporary = false
        clients[key] = client
        var subs = Set<AnyCancellable>()

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak client] state in
                guard let self, let client, self.clients[key] === client else { return }
                if state == .connected {
                    let pending = self.pendingInjections.removeValue(forKey: key) ?? []
                    for dict in pending {
                        self.sendInjection(dict, via: client)
                    }
                }
            }
            .store(in: &subs)

        cancellables[key] = subs
        client.connect(url: url)
    }

    private func sendInjection(_ eventDict: [String: Any], via client: WebSocketClient) {
        let msg: [Any] = ["EVENT", eventDict]
        if let data = try? JSONSerialization.data(withJSONObject: msg),
           let str = String(data: data, encoding: .utf8) {
            client.send(text: str)
        }
    }

    private func enqueueInjection(_ eventDict: [String: Any], for key: String) {
        var queue = pendingInjections[key, default: []]
        queue.append(eventDict)
        if queue.count > maxPendingInjections {
            queue.removeFirst(queue.count - maxPendingInjections)
        }
        pendingInjections[key] = queue
    }
}
#endif
