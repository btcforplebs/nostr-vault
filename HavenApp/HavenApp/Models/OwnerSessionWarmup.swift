import Foundation

/// When to log the owner's bunker in beside another active account, and what
/// to do once that login finishes. `NIP46Service+OwnerSession` does the Go
/// call; this decides, so the rules are testable without the bridge.
///
/// Every owner-forced AUTH (DM /chat, drafts /private, the Vault counts)
/// signs through the owner's own bunker session. After a restart with another
/// account active, nothing had logged the owner in, so each of them failed.
struct OwnerSessionWarmup {
    /// What the Go login takes.
    struct Login: Equatable {
        let link: String
        let clientSecretKey: String
        let ownerHex: String
    }

    private(set) var inFlight = false

    /// The background login to start now, or nil: the owner signs with a
    /// bunker and another account is active, no pairing secret is pending
    /// (that login has to reach the signer and may need an approval the
    /// background cannot show, like `performConnect`'s fresh pairing), the
    /// owner's client key is stored, and no login is already running.
    ///
    /// `activeSessionKey`: the Go session key of the active account's bunker
    /// (`NIP46Service.activeSignerKey()`), nil when it signs locally. When the
    /// owner's bunker shares that key (both paired to one host), Go holds one
    /// session for both: the owner's login and the active account's connect
    /// would drop each other's session, and a post could go out through the
    /// owner's. Nothing a background login does helps there, so it never starts.
    mutating func start(config: HavenConfig, ownerHex: String, activeSessionKey: String?) -> Login? {
        guard !inFlight, config.ownerNeedsBackgroundSession, !config.ownerPairingPending,
              config.ownerSessionKey != activeSessionKey,
              !ownerHex.isEmpty, let link = config.ownerBunkerLink,
              let clientSK = config.accountBunkerConfigs[config.ownerNpub]?.clientSecretKey,
              !clientSK.isEmpty else { return nil }
        inFlight = true
        return Login(link: link, clientSecretKey: clientSK, ownerHex: ownerHex)
    }

    /// The login finished with `pubkey` (nil: it failed). True when the
    /// session answers for the owner, so what could not be signed is retried.
    /// A session answering for another account is left alone, not dropped:
    /// two accounts on one signer share it.
    mutating func finished(_ login: Login, pubkey: String?) -> Bool {
        inFlight = false
        return pubkey == login.ownerHex
    }
}

/// A remote signer's reply is used only when it is signed by the key it was
/// asked to sign as. One bunker session can answer for another account (two
/// accounts paired to one host share it); without this its signature would be
/// published as the account that asked.
enum SignerReplyCheck {
    static func accepts(signedPubkey: String, askedFor: String) -> Bool {
        !askedFor.isEmpty && signedPubkey.lowercased() == askedFor.lowercased()
    }
}

/// The DM /chat AUTH challenge kept while the owner's signer is unreachable,
/// signed again once, after the owner's bunker connects in the background.
struct PendingAuthRetry {
    private(set) var challenge: String?
    private var retried = false

    /// The relay sent a challenge (a new socket, or a re-challenge).
    mutating func received(_ challenge: String) {
        self.challenge = challenge
        retried = false
    }

    /// Signing the AUTH failed. True when the owner's bunker should be logged
    /// in for a retry: only the first time, so a signer that keeps refusing
    /// cannot loop.
    func shouldWarmOwner() -> Bool { challenge != nil && !retried }

    /// The owner's bunker connected: the challenge to sign once more, or nil
    /// if it was already retried, accepted, or dropped with its socket.
    mutating func takeRetry() -> String? {
        guard let challenge, !retried else { return nil }
        retried = true
        return challenge
    }

    /// AUTH accepted, or the socket the challenge came from was rebuilt.
    mutating func reset() {
        challenge = nil
        retried = false
    }
}
