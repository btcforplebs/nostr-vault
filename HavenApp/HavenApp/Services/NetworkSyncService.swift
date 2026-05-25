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
        let relayStrings = Array(Set(config.feedRelays + config.importSeedRelays))
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

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.isStarted else { return }
                switch state {
                case .connected:
                    self.reconnectAttempts[urlStr] = 0
                    self.sendSubscription(to: client, relay: urlStr)
                case .disconnected, .error:
                    self.scheduleReconnect(to: urlStr)
                default:
                    break
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
            self?.connect(to: urlStr)
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

        guard let url = URL(string: targetURL) else { return }

        // Reuse an existing connected injection client if available, or create one
        let key = "__inject__\(targetURL)"
        if let existing = clients[key], existing.connectionState == .connected {
            let msg: [Any] = ["EVENT", eventDict]
            if let data = try? JSONSerialization.data(withJSONObject: msg),
               let str = String(data: data, encoding: .utf8) {
                existing.send(text: str)
            }
            return
        }

        let client = WebSocketClient()
        client.isTemporary = false
        clients[key] = client
        var subs = Set<AnyCancellable>()

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                if state == .connected {
                    let msg: [Any] = ["EVENT", eventDict]
                    if let data = try? JSONSerialization.data(withJSONObject: msg),
                       let str = String(data: data, encoding: .utf8) {
                        client.send(text: str)
                    }
                }
            }
            .store(in: &subs)

        cancellables[key] = subs
        client.connect(url: url)
    }
}
#endif
