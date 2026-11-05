import Foundation

/// Which signer session a NIP-46 request goes to once it leaves the queue
/// (signer audit 2026-11-05 #1). The key is recorded when the request is
/// made: a queued request for account A went to whichever session was active
/// after the wait, so a switch to bunker account B put A's DM decrypt, AUTH or
/// mute-list work in front of B's signer.
///
/// Pure Foundation so MediaLogicTests can test it.
enum NIP46SessionChoice: Equatable {
    /// The session recorded at request time (NIP46SignEventWithC / NIP46CryptWithC).
    case recorded(String)
    /// No session was known then: the active one, as before.
    case active

    static func route(recorded key: String) -> NIP46SessionChoice {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? .active : .recorded(key)
    }
}
