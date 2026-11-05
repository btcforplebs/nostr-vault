import Foundation

/// What setup does with the owner key already saved in config, each time it
/// saves (bug hunt 2026-11-05 #2/#3). A key from an earlier way through setup
/// used to stay saved next to a different npub, so an npub-only (read-only)
/// account could sign as someone else, and "New to Nostr" after a pasted nsec
/// reused that real key and overwrote its profile and relay list.
///
/// Pure Foundation so MediaLogicTests can test it.
enum SetupOwnerKey {
    /// The saved key, compared with the npub setup is saving.
    enum Stored: Equatable {
        case none
        /// It is the key for that npub.
        case matches
        /// It is some other account's key.
        case other
        /// It can't be read here (no keychain password): left alone, it can't
        /// sign anyway.
        case unreadable
    }

    enum Action: Equatable {
        /// Encrypt and save the key typed this run.
        case write
        case keep
        /// Remove the saved key (and its keychain password).
        case clear
    }

    /// `typedKey`: setup holds an nsec from this run; `hasPassword`: and the
    /// password to encrypt it; `signer`: a remote signer (NIP-46) was chosen;
    /// `npubKnown`: setup has an npub to compare with (none yet at the front
    /// door, where nothing may be cleared).
    static func action(typedKey: Bool, hasPassword: Bool, signer: Bool, npubKnown: Bool, stored: Stored) -> Action {
        if typedKey && hasPassword && !signer { return .write }
        guard npubKnown else { return .keep }
        return stored == .other ? .clear : .keep
    }

    /// Picking another way in at the front door starts over: keys typed or
    /// generated for the earlier way are not this one's. The same way again
    /// keeps them (a generated key may already be written down).
    static func resetsTypedKeys<Way: Equatable>(from previous: Way?, to next: Way) -> Bool {
        guard let previous else { return false }
        return previous != next
    }
}
