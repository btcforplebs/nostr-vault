import Foundation
import Security
#if os(iOS)
import UIKit
#endif

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

    var outstandingRequests = 0

    var authPollerTask: Task<Void, Never>?

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
    var connectedSignerPubkey: String?

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
           let cStr = withCStrings([signerKey], { p in NIP46ActivateC(p[0]) }) {
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
            withCStrings([signerKey], { p in NIP46DropC(p[0]) })
        }

        #if DEBUG
        print("[NIP46] Calling NIP46ConnectC with bunkerURL=\(bunkerURL.prefix(40))...")
        #endif

        // Start auth URL polling during connect (ConnectBunker blocks)
        startAuthURLPoller()

        // ConnectBunker is blocking in Go -- run off main actor
        let signerPubkey: String? =
        await Task.detached {
            guard let result = withCStrings([clientSK, bunkerURL], { p in NIP46ConnectC(p[0], p[1]) }) else {
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
            if outstandingRequests == 0 { stopAuthURLPoller() }
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
                withCStrings([signerKey], { p in NIP46DropC(p[0]) })
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
        // The connect is answered: stop polling for its auth challenge.
        // Requests start it again while they wait (signerRequest).
        if outstandingRequests == 0 { stopAuthURLPoller() }

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
    var lastSignerAnswer: Date = .distantPast

    /// The in-flight connect, so every caller waits on the same handshake
    /// instead of starting a second one that would re-send a single-use secret.
    var connectTask: Task<String, Error>?

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

    // MARK: - Convenience

    var isConnected: Bool {
        connectionState == .connected
    }
}
