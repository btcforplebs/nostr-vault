import Foundation

// MARK: - NIP-46 Error Types

enum NIP46Error: Error, LocalizedError {
    case notConnected
    case timeout
    case signerError(String)
    case authChallenge(String)
    case invalidResponse
    case invalidBunkerURI
    case encryptionFailed
    case signingFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to remote signer"
        case .timeout: return "Remote signer did not respond"
        case .signerError(let msg): return "Signer error: \(msg)"
        case .authChallenge(let url): return "Signer requires verification: \(url)"
        case .invalidResponse: return "Invalid response from signer"
        case .invalidBunkerURI: return "Invalid bunker:// URI"
        case .encryptionFailed: return "Failed to encrypt NIP-46 request"
        case .signingFailed: return "Failed to sign NIP-46 request event"
        }
    }
}

// MARK: - NIP46Service

@MainActor
class NIP46Service: ObservableObject {
    static let shared = NIP46Service()

    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var authChallengeURL: String?

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var authPollerTask: Task<Void, Never>?

    private init() {}

    // MARK: - Bunker URI Parsing

    struct BunkerInfo {
        let signerPubkey: String
        let relayURL: String
        let secret: String
    }

    static func parseBunkerURI(_ uri: String) throws -> BunkerInfo {
        guard let info = BunkerURI.parse(uri) else {
            throw NIP46Error.invalidBunkerURI
        }
        return BunkerInfo(signerPubkey: info.signerPubkey, relayURL: info.relayURL, secret: info.secret)
    }

    // MARK: - Connection Management

    @discardableResult
    func connect() async throws -> String {
        let config = ConfigService.shared.config
        print("[NIP46] connect() called — activeSigningMode=\(config.activeSigningMode()) bunkerURI=\(!config.nip46BunkerURI.isEmpty) signerPK=\(!config.nip46SignerPubkey.isEmpty)")
        guard config.activeSigningMode() == "nip46",
              !config.nip46BunkerURI.isEmpty || (!config.nip46SignerPubkey.isEmpty && !config.nip46RelayURL.isEmpty) else {
            print("[NIP46] connect() FAILED guard — activeSigningMode=\(config.activeSigningMode()) bunkerURI.isEmpty=\(config.nip46BunkerURI.isEmpty) signerPK.isEmpty=\(config.nip46SignerPubkey.isEmpty) relayURL.isEmpty=\(config.nip46RelayURL.isEmpty)")
            throw NIP46Error.invalidBunkerURI
        }

        // Generate client keypair if not yet created
        if config.nip46ClientSecretKey.isEmpty {
            print("[NIP46] Generating client keypair...")
            guard let keyPairCStr = GenerateKeyPairC() else {
                throw NIP46Error.signingFailed
            }
            let keyPairStr = String(cString: keyPairCStr)
            free(keyPairCStr)

            let parts = keyPairStr.split(separator: ":")
            guard parts.count == 2 else { throw NIP46Error.signingFailed }

            ConfigService.shared.config.nip46ClientSecretKey = String(parts[0])
            ConfigService.shared.config.nip46ClientPubkey = String(parts[1])
            ConfigService.shared.save()
            print("[NIP46] Client keypair generated: \(String(parts[1]).prefix(8))...")
        } else {
            print("[NIP46] Client keypair already exists: \(config.nip46ClientPubkey.prefix(8))...")
        }

        connectionState = .connecting
        reconnectAttempts = 0

        // Build bunker URL from config
        let bunkerURL: String
        if !config.nip46BunkerURI.isEmpty {
            bunkerURL = config.nip46BunkerURI
        } else {
            var urlStr = "bunker://\(config.nip46SignerPubkey)?relay=\(config.nip46RelayURL)"
            if !config.nip46Secret.isEmpty {
                urlStr += "&secret=\(config.nip46Secret)"
            }
            bunkerURL = urlStr
        }

        let clientSK = ConfigService.shared.config.nip46ClientSecretKey
        print("[NIP46] Calling NIP46ConnectC with bunkerURL=\(bunkerURL.prefix(40))...")

        // Start auth URL polling during connect (ConnectBunker blocks)
        startAuthURLPoller()

        // ConnectBunker is blocking in Go -- run off main actor
        let signerPubkey: String? =
        await Task.detached {
            guard let result = NIP46ConnectC(
                UnsafeMutablePointer(mutating: (clientSK as NSString).utf8String),
                UnsafeMutablePointer(mutating: (bunkerURL as NSString).utf8String)
            ) else {
                print("[NIP46] NIP46ConnectC returned nil")
                return nil as String?
            }
            let str = String(cString: result)
            free(result)
            print("[NIP46] NIP46ConnectC returned pubkey=\(str.prefix(8))...")
            return str
        }.value

        guard let pubkey = signerPubkey, !pubkey.isEmpty else {
            connectionState = .error
            checkPendingAuthURL()
            print("[NIP46] connect() FAILED — NIP46ConnectC returned nil")
            throw NIP46Error.notConnected
        }

        connectionState = .connected
        startPingLoop()

        // Clear the bunker secret after successful pairing — it's one-time-use
        // and must not be re-sent on reconnection attempts. The signer already
        // paired our client pubkey; future connects work without a secret.
        if !ConfigService.shared.config.nip46Secret.isEmpty {
            print("[NIP46] Clearing consumed bunker secret from config")
            ConfigService.shared.config.nip46Secret = ""
            // Strip secret from the stored bunker URI so reconnection doesn't re-send it
            if var components = URLComponents(string: ConfigService.shared.config.nip46BunkerURI) {
                components.queryItems = components.queryItems?.filter { $0.name != "secret" }
                if components.queryItems?.isEmpty == true { components.queryItems = nil }
                if let stripped = components.url?.absoluteString {
                    ConfigService.shared.config.nip46BunkerURI = stripped
                }
            }
            // Also clear secret in the per-account bunker config
            let activeNpub = ConfigService.shared.config.activeAccountNpub.isEmpty
                ? ConfigService.shared.config.ownerNpub
                : ConfigService.shared.config.activeAccountNpub
            if var bunkerCfg = ConfigService.shared.config.accountBunkerConfigs[activeNpub] {
                bunkerCfg.secret = ""
                bunkerCfg.bunkerURI = ConfigService.shared.config.nip46BunkerURI
                ConfigService.shared.config.accountBunkerConfigs[activeNpub] = bunkerCfg
            }
            ConfigService.shared.save()
        }

        print("[NIP46] connect() SUCCESS — pubkey=\(pubkey.prefix(8))...")
        RelayProcessManager.shared.addLog("NIP-46: Connected to signer \(pubkey.prefix(8))...", level: "INFO")
        return pubkey
    }

    private var connectTask: Task<Void, Never>?

    func connectFromConfig() {
        let config = ConfigService.shared.config
        guard config.activeSigningMode() == "nip46",
              !config.nip46BunkerURI.isEmpty || (!config.nip46SignerPubkey.isEmpty && !config.nip46RelayURL.isEmpty) else { return }

        // Prevent duplicate connections — if already connected or a connect is in-flight, skip.
        if connectionState == .connected || connectionState == .connecting {
            return
        }

        // Set connecting state synchronously so ensureConnected() callers
        // see it immediately, even before the Task starts executing.
        connectionState = .connecting

        connectTask?.cancel()
        connectTask = Task {
            do {
                try await connect()
            } catch {
                print("NIP46Service: Auto-connect failed: \(error.localizedDescription)")
                connectionState = .error
            }
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        authPollerTask?.cancel()
        authPollerTask = nil

        NIP46DisconnectC()

        connectionState = .disconnected
        authChallengeURL = nil

        RelayProcessManager.shared.addLog("NIP-46: Disconnected from signer", level: "INFO")
    }

    // MARK: - NIP-46 Methods

    func signEvent(eventJSON: String) async throws -> String {
        print("NIP46Service: signEvent called, connectionState=\(connectionState.rawValue)")
        try await ensureConnected()
        return try await callGo { NIP46SignEventC(
            UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String)
        )}
    }

    func getPublicKey() async throws -> String {
        guard connectionState == .connected else { throw NIP46Error.notConnected }
        return try await callGo { NIP46GetPublicKeyC() }
    }

    func ping() async throws {
        guard connectionState == .connected else { throw NIP46Error.notConnected }
        let result: Int32 = await Task.detached { NIP46PingC() }.value
        guard result == 0 else { throw NIP46Error.invalidResponse }
    }

    func nip04Encrypt(thirdPartyPubkey: String, plaintext: String) async throws -> String {
        try await ensureConnected()
        return try await callGo { NIP46NIP04EncryptC(
            UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
        )}
    }

    func nip04Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await callGo { NIP46NIP04DecryptC(
            UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String)
        )}
    }

    func nip44Encrypt(thirdPartyPubkey: String, plaintext: String) async throws -> String {
        try await ensureConnected()
        return try await callGo { NIP46NIP44EncryptC(
            UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
        )}
    }

    func nip44Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await callGo { NIP46NIP44DecryptC(
            UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
            UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String)
        )}
    }

    /// Ensures the NIP-46 connection is active, reconnecting if it dropped.
    private func ensureConnected() async throws {
        if connectionState == .connected { return }

        // If a connection is already in progress, wait for it to complete
        // rather than starting a redundant connect() that will tear down
        // the in-progress Go session behind the NIP-46 mutex.
        if connectionState == .connecting {
            for _ in 0..<60 {  // up to 30 seconds
                try? await Task.sleep(nanoseconds: 500_000_000)
                if connectionState == .connected { return }
                if connectionState != .connecting { break }
            }
            guard connectionState == .connected else {
                throw NIP46Error.notConnected
            }
            return
        }

        print("NIP46Service: ensureConnected – state=\(connectionState.rawValue), attempting reconnect…")
        do {
            try await connect()
        } catch {
            print("NIP46Service: ensureConnected reconnect failed: \(error.localizedDescription)")
            throw NIP46Error.notConnected
        }
        guard connectionState == .connected else {
            throw NIP46Error.notConnected
        }
    }

    // MARK: - Private: Go Bridge Helper

    private nonisolated func callGo(_ block: @escaping @Sendable () -> UnsafeMutablePointer<CChar>?) async throws -> String {
        let result: String? = await Task.detached {
            guard let cStr = block() else { return nil }
            let str = String(cString: cStr)
            free(cStr)
            return str
        }.value
        guard let result else {
            throw NIP46Error.signerError("Go bridge returned nil")
        }
        return result
    }

    // MARK: - Auth URL Polling

    private func startAuthURLPoller() {
        authPollerTask?.cancel()
        authPollerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                checkPendingAuthURL()
            }
        }
    }

    private func checkPendingAuthURL() {
        guard let cStr = NIP46GetPendingAuthURLC() else { return }
        let url = String(cString: cStr)
        free(cStr)
        guard !url.isEmpty else { return }
        authChallengeURL = url
        RelayProcessManager.shared.addLog("NIP-46: Auth challenge: \(url)", level: "INFO")
    }

    // MARK: - Reconnection

    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            RelayProcessManager.shared.addLog("NIP-46: Max reconnect attempts reached", level: "ERROR")
            return
        }

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)
            let jitter = Double.random(in: 0...2)
            let totalDelay = delay + jitter
            reconnectAttempts += 1

            RelayProcessManager.shared.addLog("NIP-46: Reconnecting in \(Int(totalDelay))s (attempt \(reconnectAttempts))", level: "INFO")

            try? await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))

            guard !Task.isCancelled else { return }

            do {
                try await connect()
            } catch {
                print("NIP46Service: Reconnect failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Keepalive

    private func startPingLoop() {
        pingTask?.cancel()
        pingTask = Task { @MainActor in
            while !Task.isCancelled && connectionState == .connected {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled && connectionState == .connected else { break }
                do {
                    try await ping()
                } catch {
                    print("NIP46Service: Ping failed: \(error.localizedDescription)")
                    connectionState = .error
                    scheduleReconnect()
                }
            }
        }
    }

    // MARK: - Convenience

    var isConnected: Bool {
        connectionState == .connected
    }
}
