import Foundation
import Security
#if os(iOS)
import UIKit
#endif

// MARK: - NIP-46 Error Types

enum NIP46Error: Error, LocalizedError {
    case notConnected
    case timeout
    case rejected(String)
    case offline
    case signerError(String)
    case authChallenge(String)
    case invalidResponse
    case invalidBunkerURI
    case encryptionFailed
    case signingFailed
    case wrongAccount(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to remote signer"
        case .timeout: return "Your signer didn't answer in time. Open it and check for a pending request."
        case .rejected(let msg): return msg.isEmpty ? "Your signer declined the request" : "Your signer declined the request: \(msg)"
        case .offline: return "Couldn't reach your signer's relay. Check your connection."
        case .signerError(let msg): return "Signer error: \(msg)"
        case .authChallenge(let url): return "Signer requires verification: \(url)"
        case .invalidResponse: return "Invalid response from signer"
        case .invalidBunkerURI: return "Invalid bunker:// URI"
        case .encryptionFailed: return "Failed to encrypt NIP-46 request"
        case .signingFailed: return "Failed to sign NIP-46 request event"
        case .wrongAccount(let expected, let got):
            return "This signer is for a different account (\(got.prefix(8))…), not \(expected.prefix(8))…"
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

    /// What the app is currently waiting on the signer for ("Sign your note",
    /// "Decrypt a message"), set only once a request has been outstanding long
    /// enough that the person may need to approve it. Drives the
    /// "Approve in your signer" banner.
    @Published private(set) var awaitingApproval: String?
    private var outstandingRequests = 0
    /// Outstanding requests that may show the banner (user actions only).
    private var bannerRequests = 0

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

    /// - Parameter adoptSignerAccount: true only while signing in with a signer
    ///   (setup), when there is no account yet and the signer's key *becomes*
    ///   the account. Everywhere else the signer must answer for the account
    ///   it was paired to.
    @discardableResult
    func connect(adoptSignerAccount: Bool = false) async throws -> String {
        let task = Task { try await self.performConnect(adoptSignerAccount: adoptSignerAccount) }
        connectTask = task
        return try await task.value
    }

    /// The signer pubkey of the live session, for callers that only need to
    /// know the handshake already happened.
    private var connectedSignerPubkey: String?

    private func performConnect(adoptSignerAccount: Bool) async throws -> String {
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

        // The account this connection is for. A signer is bound to one account;
        // the result is checked against this, not against whatever is active
        // when the (slow, blocking) connect finally returns.
        let accountNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        let expectedHex = Bech32.decode(accountNpub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString ?? ""

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
            throw Self.lastBridgeError() ?? NIP46Error.notConnected
        }

        // Refuse a signer that answers for a different account, and a connect
        // that finished after the user switched away from its account.
        let nowNpub = ConfigService.shared.config.activeAccountNpub.isEmpty
            ? ConfigService.shared.config.ownerNpub
            : ConfigService.shared.config.activeAccountNpub
        // Adopting only applies when there is genuinely no account to compare
        // against; otherwise the signer must answer for the account it is for.
        let adopting = adoptSignerAccount && accountNpub.isEmpty
        let accountMismatch = !adopting && (expectedHex.isEmpty || pubkey != expectedHex)
        if accountMismatch || nowNpub != accountNpub {
            NIP46DisconnectC()
            authPollerTask?.cancel()
            authPollerTask = nil
            connectionState = nowNpub != accountNpub ? .disconnected : .error
            print("[NIP46] connect() REJECTED — signer pubkey=\(pubkey.prefix(8)) expected=\(expectedHex.prefix(8)) accountChanged=\(nowNpub != accountNpub)")
            RelayProcessManager.shared.addLog("NIP-46: Signer answered for \(pubkey.prefix(8))…, expected \(expectedHex.prefix(8))… — not connected", level: "ERROR")
            throw NIP46Error.wrongAccount(expected: expectedHex, got: pubkey)
        }

        connectionState = .connected
        connectedSignerPubkey = pubkey
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
            if var bunkerCfg = ConfigService.shared.config.accountBunkerConfigs[accountNpub] {
                bunkerCfg.secret = ""
                bunkerCfg.bunkerURI = ConfigService.shared.config.nip46BunkerURI
                ConfigService.shared.config.accountBunkerConfigs[accountNpub] = bunkerCfg
            }
            ConfigService.shared.save()
        }

        print("[NIP46] connect() SUCCESS — pubkey=\(pubkey.prefix(8))...")
        RelayProcessManager.shared.addLog("NIP-46: Connected to signer \(pubkey.prefix(8))...", level: "INFO")
        return pubkey
    }

    /// The in-flight connect, so every caller waits on the same handshake
    /// instead of starting a second one that would re-send a single-use secret.
    private var connectTask: Task<String, Error>?

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
        let task = Task { try await self.performConnect(adoptSignerAccount: false) }
        connectTask = task
        Task {
            do {
                _ = try await task.value
            } catch {
                print("NIP46Service: Auto-connect failed: \(error.localizedDescription)")
                if connectionState == .connecting { connectionState = .error }
            }
        }
    }

    /// Waits for the connect already in flight, or starts one. Use this after
    /// anything that may have kicked off `connectFromConfig()`; it surfaces the
    /// real failure (wrong account, declined, timed out) instead of a generic one.
    @discardableResult
    func waitForConnection() async throws -> String {
        if connectionState == .connected, let pubkey = connectedSignerPubkey {
            return pubkey
        }
        if connectionState == .connecting, let task = connectTask {
            return try await task.value
        }
        return try await connect()
    }

    /// Called when the app comes back to the foreground. The session is kept
    /// across backgrounding (so a request approved in the signer still lands),
    /// but the socket may have died while suspended: ping it, and reconnect
    /// only if the signer no longer answers.
    func resumeAfterForeground() {
        let config = ConfigService.shared.config
        guard config.activeSigningMode() == "nip46" else { return }
        guard connectionState == .connected else {
            connectFromConfig()
            return
        }
        // A reconnect tears down the session, and with it any request still
        // waiting on an answer — possibly one the user just approved. Leave a
        // session with work in flight alone; the ping loop covers it after.
        guard outstandingRequests == 0 else { return }
        Task {
            do {
                try await ping()
            } catch {
                // Only if nothing else (a disconnect, an account switch) has
                // moved the session on while the ping was out.
                guard connectionState == .connected, outstandingRequests == 0 else { return }
                print("NIP46Service: resume ping failed, reconnecting: \(error.localizedDescription)")
                connectionState = .error
                connectFromConfig()
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
        connectedSignerPubkey = nil
        authChallengeURL = nil

        RelayProcessManager.shared.addLog("NIP-46: Disconnected from signer", level: "INFO")
    }

    // MARK: - NIP-46 Methods

    func signEvent(eventJSON: String) async throws -> String {
        print("NIP46Service: signEvent called, connectionState=\(connectionState.rawValue)")
        try await ensureConnected()
        let label = Self.approvalLabel(forEventJSON: eventJSON)
        return try await signerRequest(label) {
            try await self.callGo { NIP46SignEventC(
                UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String)
            )}
        }
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
        return try await signerRequest(nil) {
            try await self.callGo { NIP46NIP04EncryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
            )}
        }
    }

    func nip04Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(nil) {
            try await self.callGo { NIP46NIP04DecryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String)
            )}
        }
    }

    func nip44Encrypt(thirdPartyPubkey: String, plaintext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(nil) {
            try await self.callGo { NIP46NIP44EncryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
            )}
        }
    }

    func nip44Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(nil) {
            try await self.callGo { NIP46NIP44DecryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String)
            )}
        }
    }

    /// Ensures the NIP-46 connection is active, reconnecting if it dropped.
    private func ensureConnected() async throws {
        if connectionState == .connected { return }

        // If a connection is already in progress, wait for it to complete
        // rather than starting a redundant connect() that will tear down
        // the in-progress Go session behind the NIP-46 mutex.
        if connectionState == .connecting {
            if let task = connectTask {
                _ = try await task.value
            } else {
                for _ in 0..<60 {  // up to 30 seconds
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if connectionState == .connected { return }
                    if connectionState != .connecting { break }
                }
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
            throw error
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
            throw Self.lastBridgeError() ?? NIP46Error.signerError("Go bridge returned nil")
        }
        return result
    }

    /// Why the last NIP-46 bridge call returned nil, as classified by the Go
    /// side (`NIP46LastErrorC`). Nil when it recorded nothing.
    private nonisolated static func lastBridgeError() -> NIP46Error? {
        guard let cStr = NIP46LastErrorC() else { return nil }
        let raw = String(cString: cStr)
        free(cStr)
        switch raw {
        case "": return nil
        case "timeout": return .timeout
        case "disconnected": return .notConnected
        case "offline": return .offline
        default:
            if raw.hasPrefix("rejected:") { return .rejected(String(raw.dropFirst("rejected:".count))) }
            if raw.hasPrefix("error:") { return .signerError(String(raw.dropFirst("error:".count))) }
            return .signerError(raw)
        }
    }

    /// Runs one request to the signer. Keeps the app alive in the background
    /// while it is outstanding (so switching to the signer to approve doesn't
    /// kill it), and after a short grace raises the "Approve in your signer"
    /// banner — a request the signer auto-approves never shows it.
    /// Kinds a person signs by doing something (posting, reacting, following,
    /// sending a DM — kind 13 is the DM seal). Everything else the app signs on
    /// its own — relay AUTH (22242), Blossom and HTTP auth (24242, 27235),
    /// list syncs — and must never put up the approval banner: those run all
    /// the time, and a banner that is always up means nothing.
    private static let userActionKinds: Set<Int> = [0, 1, 3, 5, 6, 7, 9, 13, 16, 20, 21, 22, 1111, 1984, 9734, 30023]

    private nonisolated static func approvalLabel(forEventJSON json: String) -> String? {
        struct KindOnly: Decodable { let kind: Int }
        guard let data = json.data(using: .utf8),
              let kind = try? JSONDecoder().decode(KindOnly.self, from: data).kind,
              userActionKinds.contains(kind) else { return nil }
        return kind == 13 ? "Approve sending your message" : "Approve in your signer"
    }

    /// - Parameter label: banner text if this request waits on the person, or
    ///   nil for background work (decrypting the DM backlog, relay AUTH), which
    ///   never shows the banner however long the signer takes.
    private func signerRequest<T>(_ label: String?, _ body: @escaping () async throws -> T) async throws -> T {
        outstandingRequests += 1
        if label != nil { bannerRequests += 1 }
        #if os(iOS)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "NIP46Request") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        #endif
        let banner = Task { @MainActor in
            guard let label else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { self.awaitingApproval = label }
        }
        defer {
            banner.cancel()
            outstandingRequests -= 1
            if label != nil { bannerRequests -= 1 }
            if bannerRequests == 0 { awaitingApproval = nil }
            #if os(iOS)
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            #endif
        }
        return try await body()
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

    // MARK: - Sign in with a signer app (nostrconnect://)

    /// One pairing attempt in the client-initiated flow: we show a
    /// nostrconnect:// URI carrying our pubkey and a fresh secret, and the
    /// signer app (Clave) answers with that secret. Kept for the whole attempt
    /// so "Open Clave again" re-sends the SAME request — Clave answers an
    /// already-approved one silently instead of asking twice.
    struct NostrConnectRequest {
        let uri: String
        let clientSecretKey: String
        let clientPubkey: String
        let secret: String
        let relays: [String]
        let startedAt: Int
    }

    /// relay.powr.build is the relay Clave's push proxy watches, so a request
    /// there wakes Clave even when it is closed, and it keeps kind 24133 so an
    /// answer sent while we were suspended can be read back. damus keeps them
    /// too.
    nonisolated static let nostrConnectRelays = ["wss://relay.powr.build", "wss://relay.damus.io"]

    /// Where Clave sends the user back after they approve (its `callback=`).
    /// Any nostrvault:// URL just brings the app forward.
    nonisolated static let nostrConnectCallback = "nostrvault://signer-return"

    func makeNostrConnectRequest(includeCallback: Bool) -> NostrConnectRequest? {
        guard let keyPairCStr = GenerateKeyPairC() else { return nil }
        let keyPair = String(cString: keyPairCStr)
        free(keyPairCStr)
        let parts = keyPair.split(separator: ":")
        guard parts.count == 2 else { return nil }
        let clientSK = String(parts[0]), clientPK = String(parts[1])

        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()

        var components = URLComponents()
        components.scheme = "nostrconnect"
        components.host = clientPK
        var items = Self.nostrConnectRelays.map { URLQueryItem(name: "relay", value: $0) }
        items += [
            URLQueryItem(name: "secret", value: secret),
            URLQueryItem(name: "perms", value: "sign_event,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt"),
            URLQueryItem(name: "name", value: "Nostr Vault"),
            URLQueryItem(name: "url", value: "https://nostrvault.app"),
            URLQueryItem(name: "image", value: "https://nostrvault.app/assets/haven_icon.png"),
        ]
        if includeCallback {
            items.append(URLQueryItem(name: "callback", value: Self.nostrConnectCallback))
        }
        components.queryItems = items
        // URLComponents leaves ":" and "/" in query values as-is; signers
        // (Clave's parser included) read them fine, but encode "+" which some
        // decoders turn into a space.
        guard let uri = components.string?.replacingOccurrences(of: "+", with: "%2B") else { return nil }
        return NostrConnectRequest(uri: uri, clientSecretKey: clientSK, clientPubkey: clientPK,
                                   secret: secret, relays: Self.nostrConnectRelays,
                                   startedAt: Int(Date().timeIntervalSince1970) - 5)
    }

    /// Clave's Universal Link for a nostrconnect URI. Opens Clave when it is
    /// installed (without the nostrconnect:// scheme, which any app can claim)
    /// and a page with install links and a QR code when it is not.
    nonisolated static func claveLink(for request: NostrConnectRequest) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = request.uri.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://clave.casa/connect/?uri=\(encoded)")
    }

    /// Waits for the signer's answer to `request`, in short rounds so the
    /// caller's task can be cancelled between them. Returns the signer pubkey.
    func awaitNostrConnect(_ request: NostrConnectRequest, timeout: TimeInterval = 300) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let relaysJSON = (try? String(data: JSONEncoder().encode(request.relays), encoding: .utf8)) ?? "[]"
        while Date() < deadline {
            try Task.checkCancellation()
            let pubkey: String? = await Task.detached {
                guard let cStr = NIP46AwaitNostrConnectC(
                    UnsafeMutablePointer(mutating: (request.clientSecretKey as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (relaysJSON as NSString).utf8String),
                    UnsafeMutablePointer(mutating: (request.secret as NSString).utf8String),
                    Int64(request.startedAt),
                    15
                ) else { return nil as String? }
                let str = String(cString: cStr)
                free(cStr)
                return str
            }.value
            if let pubkey, !pubkey.isEmpty { return pubkey }
        }
        throw NIP46Error.timeout
    }

    /// The bunker:// form of a finished nostrconnect pairing: how every later
    /// reconnect reaches the signer. No secret — the pairing is already made,
    /// and Clave answers a paired app's connect with "ack".
    nonisolated static func bunkerURI(signerPubkey: String, relays: [String]) -> String {
        var components = URLComponents()
        components.scheme = "bunker"
        components.host = signerPubkey
        components.queryItems = relays.map { URLQueryItem(name: "relay", value: $0) }
        return components.string ?? "bunker://\(signerPubkey)"
    }

    // MARK: - Convenience

    var isConnected: Bool {
        connectionState == .connected
    }
}
