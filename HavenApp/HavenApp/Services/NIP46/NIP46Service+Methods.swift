import Foundation
import Security
#if os(iOS)
import UIKit
#endif

extension NIP46Service {
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
        HavenConfig.signerSessionKey(bunkerURI: bunkerURI, signerPubkey: signerPubkey)
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
}
