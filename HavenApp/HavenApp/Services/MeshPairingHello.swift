import Combine
import Foundation

/// Pairing hellos and acks on the finder relays: ephemeral kind-21195 events,
/// NIP-44 encrypted from this device's mesh key to the other device's, signed
/// by the mesh key (docs/MESH_PAIRING_CONTRACT.md §3).
///
/// The only reader of the mesh nsec outside the engine (plan T2): it is read
/// from the keychain for each sign or decrypt and dropped after, never logged,
/// never handed to UI code, and it signs kind 21195 only, through no general
/// signing function.
final class MeshPairingHello: @unchecked Sendable {
    struct Incoming: Equatable {
        let senderHex: String
        let content: String
    }

    /// This device's mesh address, read from the stored key (it never makes one).
    struct OwnMesh: Equatable {
        let hex: String
        let npub: String
    }

    static let resendInterval: TimeInterval = 8

    private let ownHex: String
    private let relays: [URL]
    private let onMessage: @MainActor (Incoming) -> Void
    private let lock = NSLock()
    private var clients: [WebSocketClient] = []
    private var cancellables: Set<AnyCancellable> = []
    private var seen = Set<String>()
    /// Signed events still being sent, each resent byte for byte (contract §3).
    private var outbox: [String] = []
    private var resendTimer: Timer?
    private var stopped = false
    private let subId = "nvpair-" + String(UUID().uuidString.prefix(8)).lowercased()
    private let since = Int(Date().timeIntervalSince1970) - 30

    init(own: OwnMesh, relays: [String], onMessage: @escaping @MainActor (Incoming) -> Void) {
        ownHex = own.hex
        self.relays = relays.compactMap(URL.init(string:))
        self.onMessage = onMessage
    }

    deinit { stop() }

    // MARK: Own key

    static func ownMesh() -> OwnMesh? {
        guard let sk = readSecretHex(), let pk = publicHex(secretHex: sk) else { return nil }
        return OwnMesh(hex: pk, npub: MeshPairing.npub(hex: pk))
    }

    /// The finder relays the engine uses on this device.
    @MainActor static var finderRelays: [String] {
        #if os(iOS)
        FipsMeshSettings.finderRelays
        #else
        MeshDevicesLogic.defaultFinderRelays
        #endif
    }

    // MARK: Relays

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard clients.isEmpty, !stopped else { return }
        for url in relays {
            let client = WebSocketClient()
            client.isTemporary = true
            client.$connectionState
                .removeDuplicates()
                .sink { [weak self, weak client] state in
                    guard let self, let client else { return }
                    switch state {
                    case .connected: self.opened(client)
                    case .disconnected, .error: self.dropped(client, url: url)
                    default: break
                    }
                }
                .store(in: &cancellables)
            client.messageSubject
                .sink { [weak self] text in self?.received(text) }
                .store(in: &cancellables)
            clients.append(client)
            client.connect(url: url)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: Self.resendInterval, repeats: true) { [weak self] _ in
                self?.resend()
            }
            self.lock.lock()
            if self.stopped { timer.invalidate() } else { self.resendTimer = timer }
            self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let all = clients
        clients = []
        cancellables = []
        outbox = []
        resendTimer?.invalidate()
        resendTimer = nil
        lock.unlock()
        for client in all { client.disconnect() }
    }

    /// Encrypts `content` to `toHex`, signs it with the mesh key and sends it
    /// to every finder relay, then again every few seconds, the same event,
    /// until `stop`. False when the key can't be read or the event can't be made.
    @discardableResult
    func send(_ content: String, toHex: String) -> Bool {
        guard let message = Self.signedMessage(content: content, toHex: toHex, ownHex: ownHex) else { return false }
        lock.lock()
        outbox.append(message)
        let all = clients
        lock.unlock()
        for client in all { client.send(text: message) }
        return true
    }

    private func opened(_ client: WebSocketClient) {
        let filter: [String: Any] = ["kinds": [MeshPairing.helloKind], "#p": [ownHex], "since": since]
        guard let data = try? JSONSerialization.data(withJSONObject: ["REQ", subId, filter]),
              let req = String(data: data, encoding: .utf8) else { return }
        client.send(text: req)
        lock.lock()
        let pending = outbox
        lock.unlock()
        for message in pending { client.send(text: message) }
    }

    private func dropped(_ client: WebSocketClient, url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak client] in
            guard let self, let client else { return }
            self.lock.lock()
            let live = !self.stopped && self.clients.contains { $0 === client }
            self.lock.unlock()
            if live, client.connectionState != .connected, client.connectionState != .connecting {
                client.connect(url: url)
            }
        }
    }

    private func resend() {
        lock.lock()
        let pending = outbox
        let all = clients
        lock.unlock()
        for client in all where client.connectionState == .connected {
            for message in pending { client.send(text: message) }
        }
    }

    private func received(_ text: String) {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 3, array[0] as? String == "EVENT", array[1] as? String == subId,
              let event = array[2] as? [String: Any],
              let id = event["id"] as? String,
              let sender = event["pubkey"] as? String,
              let ciphertext = event["content"] as? String,
              let tags = event["tags"] as? [[String]],
              (event["kind"] as? Int) == MeshPairing.helloKind,
              tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == ownHex }) else { return }
        // The relay can send anything under any author: only a valid
        // signature says the sender's mesh key made it. Marked seen only
        // after that, so a broken copy reusing the real id can't hide the
        // real event (Tron, PR 1704).
        guard NostrEventVerifier.isValid(event) else { return }
        lock.lock()
        let fresh = seen.insert(id).inserted
        lock.unlock()
        guard fresh, let plain = Self.decrypt(ciphertext, from: sender) else { return }
        let incoming = Incoming(senderHex: sender.lowercased(), content: plain)
        let deliver = onMessage
        Task { @MainActor in deliver(incoming) }
    }

    // MARK: Mesh key (read per call, never held)

    private static func signedMessage(content: String, toHex: String, ownHex: String) -> String? {
        guard let sk = readSecretHex(),
              let encrypted = try? NIP44Service.encrypt(plaintext: content, recipientPubkey: toHex, senderPrivkey: sk) else { return nil }
        let unsigned = EventPublisher.buildUnsignedEvent(pubkey: ownHex, kind: MeshPairing.helloKind,
                                                         content: encrypted, tags: [["p", toHex]])
        guard let json = try? JSONSerialization.data(withJSONObject: unsigned),
              let jsonString = String(data: json, encoding: .utf8),
              let signed = EventPublisher.signWithGoBackend(eventJSON: jsonString, secretKey: sk),
              signed.pubkey == ownHex, signed.kind == MeshPairing.helloKind,
              let eventData = try? JSONEncoder().encode(signed),
              let eventString = String(data: eventData, encoding: .utf8) else { return nil }
        return "[\"EVENT\",\(eventString)]"
    }

    private static func decrypt(_ ciphertext: String, from sender: String) -> String? {
        guard let sk = readSecretHex() else { return nil }
        return try? NIP44Service.decrypt(ciphertext: ciphertext, senderPubkey: sender, recipientPrivkey: sk)
    }

    private static func publicHex(secretHex: String) -> String? {
        guard let pk = withCStrings([secretHex], { p in GetPublicKeyC(p[0]) }) else { return nil }
        defer { free(pk) }
        return String(cString: pk).lowercased()
    }

    /// The engine's key (FipsMeshService / MacFipsMeshService), read only:
    /// a missing key is the engine's to make.
    private static func readSecretHex() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MeshIdentityReset.keychainService,
            kSecAttrAccount as String: "mesh-nsec",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let nsec = String(data: data, encoding: .utf8),
              let decoded = Bech32.decode(nsec), decoded.hrp == "nsec", decoded.data.count == 32 else { return nil }
        return decoded.hexString
    }
}
