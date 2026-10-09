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
    /// Background signer requests queue here, one at a time.
    static let backgroundGate = SignerRequestGate()
    /// How long one background request may hold `backgroundGate`.
    static let backgroundLease: UInt64 = 15_000_000_000

    static let shared = NIP46Service()

    enum ConnectionState: String {
        case disconnected
        case connecting
        case connected
        case error
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var authChallengeURL: String?

    private var outstandingRequests = 0

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
        #if DEBUG
        print("[NIP46] connect() called — activeSigningMode=\(config.activeSigningMode()) bunkerURI=\(!config.nip46BunkerURI.isEmpty) signerPK=\(!config.nip46SignerPubkey.isEmpty)")
        #endif
        guard config.activeSigningMode() == "nip46",
              !config.nip46BunkerURI.isEmpty || (!config.nip46SignerPubkey.isEmpty && !config.nip46RelayURL.isEmpty) else {
            #if DEBUG
            print("[NIP46] connect() FAILED guard — activeSigningMode=\(config.activeSigningMode()) bunkerURI.isEmpty=\(config.nip46BunkerURI.isEmpty) signerPK.isEmpty=\(config.nip46SignerPubkey.isEmpty) relayURL.isEmpty=\(config.nip46RelayURL.isEmpty)")
            #endif
            throw NIP46Error.invalidBunkerURI
        }

        // Generate client keypair if not yet created
        if config.nip46ClientSecretKey.isEmpty {
            #if DEBUG
            print("[NIP46] Generating client keypair...")
            #endif
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
            #if DEBUG
            print("[NIP46] Client keypair generated: \(String(parts[1]).prefix(8))...")
            #endif
        } else {
            #if DEBUG
            print("[NIP46] Client keypair already exists: \(config.nip46ClientPubkey.prefix(8))...")
            #endif
        }

        connectionState = .connecting

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

        // Switching back to an account whose signer session is still alive:
        // make it active and go. No connect / get_public_key round trip, so
        // nothing reaches the signer at all.
        let signerKey = Self.signerKey(bunkerURI: bunkerURL, signerPubkey: config.nip46SignerPubkey)
        // A fresh pairing (a new bunker link still carrying its single-use
        // secret) must reach the signer, not reuse an older session.
        let freshPairing = !config.nip46Secret.isEmpty
        if !signerKey.isEmpty, !freshPairing,
           let cStr = NIP46ActivateC(UnsafeMutablePointer(mutating: (signerKey as NSString).utf8String)) {
            let cached = String(cString: cStr)
            free(cStr)
            // No ping first: the session's relay pool redials a dropped socket
            // on its own, and a signer app asleep on the phone (Clave) misses
            // a ping — which used to throw away a working session and log in
            // from scratch (up to 90 s, often a fresh approval) on every switch.
            if cached == expectedHex {
                connectionState = .connected
                connectedSignerPubkey = cached
                #if DEBUG
                print("[NIP46] connect() reused live session for \(cached.prefix(8))")
                #endif
                RelayProcessManager.shared.addLog("NIP-46: Switched to signer \(cached.prefix(8))... (already connected)", level: "INFO")
                return cached
            }
            NIP46DropC(UnsafeMutablePointer(mutating: (signerKey as NSString).utf8String))
        }

        #if DEBUG
        print("[NIP46] Calling NIP46ConnectC with bunkerURL=\(bunkerURL.prefix(40))...")
        #endif

        // Start auth URL polling during connect (ConnectBunker blocks)
        startAuthURLPoller()

        // ConnectBunker is blocking in Go -- run off main actor
        let signerPubkey: String? =
        await Task.detached {
            guard let result = NIP46ConnectC(
                UnsafeMutablePointer(mutating: (clientSK as NSString).utf8String),
                UnsafeMutablePointer(mutating: (bunkerURL as NSString).utf8String)
            ) else {
                #if DEBUG
                print("[NIP46] NIP46ConnectC returned nil")
                #endif
                return nil as String?
            }
            let str = String(cString: result)
            free(result)
            #if DEBUG
            print("[NIP46] NIP46ConnectC returned pubkey=\(str.prefix(8))...")
            #endif
            return str
        }.value

        guard let pubkey = signerPubkey, !pubkey.isEmpty else {
            connectionState = .error
            checkPendingAuthURL()
            #if DEBUG
            print("[NIP46] connect() FAILED — NIP46ConnectC returned nil")
            #endif
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
            // A signer that answered for the wrong account is closed. A login
            // that finished after a switch is kept in the background for when
            // that account is active again; the Go side did not make it active.
            if accountMismatch {
                NIP46DropC(UnsafeMutablePointer(mutating: (signerKey as NSString).utf8String))
            }
            authPollerTask?.cancel()
            authPollerTask = nil
            connectionState = nowNpub != accountNpub ? .disconnected : .error
            #if DEBUG
            print("[NIP46] connect() REJECTED — signer pubkey=\(pubkey.prefix(8)) expected=\(expectedHex.prefix(8)) accountChanged=\(nowNpub != accountNpub)")
            #endif
            RelayProcessManager.shared.addLog("NIP-46: Signer answered for \(pubkey.prefix(8))…, expected \(expectedHex.prefix(8))… — not connected", level: "ERROR")
            throw NIP46Error.wrongAccount(expected: expectedHex, got: pubkey)
        }

        connectionState = .connected
        connectedSignerPubkey = pubkey
        lastSignerAnswer = Date()

        // Clear the bunker secret after successful pairing — it's one-time-use
        // and must not be re-sent on reconnection attempts. The signer already
        // paired our client pubkey; future connects work without a secret.
        if !ConfigService.shared.config.nip46Secret.isEmpty {
            #if DEBUG
            print("[NIP46] Clearing consumed bunker secret from config")
            #endif
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

        #if DEBUG
        print("[NIP46] connect() SUCCESS — pubkey=\(pubkey.prefix(8))...")
        #endif
        RelayProcessManager.shared.addLog("NIP-46: Connected to signer \(pubkey.prefix(8))...", level: "INFO")
        return pubkey
    }

    /// When the signer last answered anything. A live session proved at no
    /// cost, used in place of a fresh ping.
    private var lastSignerAnswer: Date = .distantPast

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
                #if DEBUG
                print("NIP46Service: Auto-connect failed: \(error.localizedDescription)")
                #endif
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
        // session with work in flight alone.
        guard outstandingRequests == 0 else { return }
        // The signer answered something a moment ago, so it is there: don't
        // ask again. Leaving the app and coming straight back — to approve in
        // the signer, to pick a photo — used to cost a ping every time.
        guard Date().timeIntervalSince(lastSignerAnswer) > 60 else { return }
        Task {
            do {
                try await ping()
            } catch {
                // Only if nothing else (a disconnect, an account switch) has
                // moved the session on while the ping was out.
                guard connectionState == .connected, outstandingRequests == 0 else { return }
                #if DEBUG
                print("NIP46Service: resume ping failed, reconnecting: \(error.localizedDescription)")
                #endif
                connectionState = .error
                connectFromConfig()
            }
        }
    }

    /// Leaves the current account's signer session connected in the
    /// background and stops treating it as this app's signer. Used on account
    /// switch, so switching back is instant instead of a fresh login.
    func detachForAccountSwitch() {
        connectTask?.cancel()
        connectTask = nil
        authPollerTask?.cancel()
        authPollerTask = nil
        connectionState = .disconnected
        connectedSignerPubkey = nil
        authChallengeURL = nil
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        authPollerTask?.cancel()
        authPollerTask = nil

        NIP46DisconnectC()

        connectionState = .disconnected
        connectedSignerPubkey = nil
        authChallengeURL = nil

        RelayProcessManager.shared.addLog("NIP-46: Disconnected from signer", level: "INFO")
    }

    // MARK: - NIP-46 Methods

    /// Signs through `signerPubkey`'s session without making it active and
    /// without logging in: the owner's relay AUTH while another bunker account
    /// is active. No live session means an error, not a request to a signer
    /// that cannot sign for that key.
    func signEvent(eventJSON: String, withSigner signerPubkey: String) async throws -> String {
        return try await signerRequest(userAction: Self.isUserAction(eventJSON: eventJSON), queued: Self.waitsInBackgroundQueue(eventJSON: eventJSON)) {
            try await self.callGo { NIP46SignEventWithC(
                UnsafeMutablePointer(mutating: (signerPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String)
            )}
        }
    }

    func signEvent(eventJSON: String) async throws -> String {
        #if DEBUG
        print("NIP46Service: signEvent called, connectionState=\(connectionState.rawValue)")
        #endif
        try await ensureConnected()
        let userAction = Self.isUserAction(eventJSON: eventJSON)
        // The session this request goes to, so a late failure can never drop
        // the session of an account switched to while it was waiting.
        let sessionKey = Self.activeSignerKey()
        do {
            return try await signerRequest(userAction: userAction, queued: Self.waitsInBackgroundQueue(eventJSON: eventJSON)) {
                try await self.callGo { NIP46SignEventC(
                    UnsafeMutablePointer(mutating: (eventJSON as NSString).utf8String)
                )}
            }
        } catch let error as NIP46Error {
            // Only something the person did (a post, a reaction): background
            // requests such as relay AUTH routinely go unanswered and say
            // nothing about the session.
            if userAction, case .timeout = error { await recheckSession(sessionKey) }
            if userAction, case .offline = error { await recheckSession(sessionKey) }
            throw error
        }
    }

    /// The Go-side key of the active account's signer session.
    static func activeSignerKey() -> String {
        let config = ConfigService.shared.config
        return signerKey(bunkerURI: config.nip46BunkerURI, signerPubkey: config.nip46SignerPubkey)
    }

    static func signerKey(bunkerURI: String, signerPubkey: String) -> String {
        URLComponents(string: bunkerURI)?.host ?? signerPubkey
    }

    /// Closes one signer's Go session, e.g. when its account is paired again
    /// with a new link: switching to it must then log in with that link.
    static func dropSession(signerKey: String) {
        guard !signerKey.isEmpty else { return }
        NIP46DropC(UnsafeMutablePointer(mutating: (signerKey as NSString).utf8String))
    }

    /// A post the signer never answered may mean a broken session: a relay can
    /// close the reply subscription for good, or the reply listener can sit in
    /// a long redial backoff after an outage. It may also just mean nobody
    /// approved it in time. One ping tells them apart; only if that fails too
    /// is the session dropped, so the next request logs in afresh. (Pings
    /// alone no longer drop sessions — a sleeping signer app misses them.)
    private func recheckSession(_ sessionKey: String) async {
        guard !sessionKey.isEmpty, connectionState == .connected, outstandingRequests == 0,
              Self.activeSignerKey() == sessionKey else { return }
        if (try? await ping()) != nil { return }
        // Re-check: a switch or another request may have moved on meanwhile.
        guard connectionState == .connected, outstandingRequests == 0,
              Self.activeSignerKey() == sessionKey else { return }
        Self.dropSession(signerKey: sessionKey)
        connectionState = .error
        connectedSignerPubkey = nil
        #if DEBUG
        print("NIP46Service: signer did not answer a request or a ping; dropped the session, next request logs in again")
        #endif
        RelayProcessManager.shared.addLog("NIP-46: Signer did not answer — will log in again on the next request", level: "ERROR")
    }

    func getPublicKey() async throws -> String {
        guard connectionState == .connected else { throw NIP46Error.notConnected }
        return try await callGo { NIP46GetPublicKeyC() }
    }

    func ping() async throws {
        guard connectionState == .connected else { throw NIP46Error.notConnected }
        let result: Int32 = await Task.detached { NIP46PingC() }.value
        guard result == 0 else { throw NIP46Error.invalidResponse }
        lastSignerAnswer = Date()
    }

    func nip04Encrypt(thirdPartyPubkey: String, plaintext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(userAction: false, queued: false) {
            try await self.callGo { NIP46NIP04EncryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
            )}
        }
    }

    func nip04Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(userAction: false) {
            try await self.callGo { NIP46NIP04DecryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (ciphertext as NSString).utf8String)
            )}
        }
    }

    func nip44Encrypt(thirdPartyPubkey: String, plaintext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(userAction: false, queued: false) {
            try await self.callGo { NIP46NIP44EncryptC(
                UnsafeMutablePointer(mutating: (thirdPartyPubkey as NSString).utf8String),
                UnsafeMutablePointer(mutating: (plaintext as NSString).utf8String)
            )}
        }
    }

    func nip44Decrypt(thirdPartyPubkey: String, ciphertext: String) async throws -> String {
        try await ensureConnected()
        return try await signerRequest(userAction: false) {
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

        #if DEBUG
        print("NIP46Service: ensureConnected – state=\(connectionState.rawValue), attempting reconnect…")
        #endif
        do {
            try await connect()
        } catch {
            #if DEBUG
            print("NIP46Service: ensureConnected reconnect failed: \(error.localizedDescription)")
            #endif
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

    /// Kinds a person signs by doing something (posting, reacting, following,
    /// sending a DM — kind 13 is the DM seal). Everything else the app signs on
    /// its own — relay AUTH (22242), Blossom and HTTP auth (24242, 27235),
    /// list syncs — and waits in the background queue.
    private static let userActionKinds: Set<Int> = [0, 1, 3, 5, 6, 7, 9, 13, 16, 20, 21, 22, 1111, 1984, 9734, 10015, 30023]

    /// Upload auth: Blossom (24242) and HTTP auth (27235). Signed without a
    /// banner like other background work, but almost always because the person
    /// just attached a photo, so it skips the background queue. Queued, a photo
    /// post waited silently behind relay AUTH and DM decrypts.
    private static let uploadAuthKinds: Set<Int> = [24242, 27235]

    private nonisolated static func kind(ofEventJSON json: String) -> Int? {
        struct KindOnly: Decodable { let kind: Int }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(KindOnly.self, from: data).kind
    }

    private nonisolated static func isUserAction(eventJSON json: String) -> Bool {
        guard let kind = kind(ofEventJSON: json) else { return false }
        return userActionKinds.contains(kind)
    }

    private nonisolated static func waitsInBackgroundQueue(eventJSON json: String) -> Bool {
        guard let kind = kind(ofEventJSON: json) else { return true }
        return !uploadAuthKinds.contains(kind)
    }

    /// Runs one request to the signer, keeping the app alive in the background
    /// while it is outstanding so switching to the signer to approve doesn't
    /// kill it.
    ///
    /// No "approve in your signer" banner: it could not tell a prompt from an
    /// auto-approve on a slow relay, so it went up for nearly every action and
    /// stayed until the slowest one answered. The signer prompts on its own,
    /// and a rejection or timeout surfaces as an error.
    ///
    /// - Parameter userAction: true for something the person did (a post, a
    ///   reaction); false for background work (decrypting the DM backlog,
    ///   relay AUTH).
    private func signerRequest<T>(userAction: Bool, queued: Bool = true, _ body: @escaping () async throws -> T) async throws -> T {
        // Background work (decrypting the DM backlog, relay AUTH, Blossom auth,
        // list syncs) goes to the signer one request at a time, however many
        // callers ask at once. Things the person did (userAction) skip the
        // queue so a post never waits behind a backlog.
        //
        // A request holds the queue for at most `backgroundLease`. The signer can
        // leave one unanswered for the full 90 s bridge timeout (relay AUTH after
        // the app comes back to the foreground does this), and everything behind
        // it used to wait the whole time. Past the lease the request keeps
        // waiting for its answer, it just stops holding up the rest.
        let gated = !userAction && queued
        var ticket: UInt64?
        if gated {
            let held = await Self.backgroundGate.wait()
            ticket = held
            Task {
                try? await Task.sleep(nanoseconds: Self.backgroundLease)
                await Self.backgroundGate.signal(held)
            }
        }
        defer { if let ticket { Task { await Self.backgroundGate.signal(ticket) } } }
        outstandingRequests += 1
        #if os(iOS)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "NIP46Request") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        #endif
        defer {
            outstandingRequests -= 1
            #if os(iOS)
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            #endif
        }
        let answer = try await body()
        lastSignerAnswer = Date()
        return answer
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

    // MARK: - Keepalive
    //
    // There is none, on purpose. A kind 24133 `ping` is a request like any
    // other: it crosses the relay and wakes the signer app. The old 60 s loop
    // sent one every minute the app was open and then did nothing with the
    // answer — a failure no longer drops the session, because a signer app
    // asleep on the phone misses pings. go-nostr's pool redials a dropped
    // socket and re-subscribes for replies on its own, and a session that is
    // genuinely gone is found by `recheckSession` on the first request that
    // goes unanswered. So the loop was pure traffic to the person's signer.

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

/// A one-at-a-time gate for background signer requests.
///
/// Each holder gets a ticket, and only that ticket can release the slot, once.
/// That lets a holder's slot be taken back on a timer (`lease`) while its
/// request is still waiting on the signer, without its later release freeing
/// the slot out from under whoever got it next.
actor SignerRequestGate {
    private var holder: UInt64?
    private var nextTicket: UInt64 = 0
    private var waiters: [(ticket: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

    func wait() async -> UInt64 {
        nextTicket += 1
        let ticket = nextTicket
        if holder == nil { holder = ticket; return ticket }
        await withCheckedContinuation { waiters.append((ticket, $0)) }
        return ticket
    }

    /// Frees the slot if `ticket` still holds it; otherwise does nothing.
    func signal(_ ticket: UInt64) {
        guard holder == ticket else { return }
        if waiters.isEmpty {
            holder = nil
        } else {
            let next = waiters.removeFirst()
            holder = next.ticket
            next.continuation.resume()
        }
    }
}
