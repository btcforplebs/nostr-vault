import Foundation

/// When the DM inbox may put a request in front of a signer that needs a
/// person (a NIP-46 bunker), and which waiting gift wraps an automatic retry
/// may ask about again (signer audit item 5,
/// RESEARCH/NV_SIGNER_AUDIT_2026_11_05.md).
///
/// With a bunker, every foreground used to ask for the vault login (read
/// AUTH on the user's relays, the /chat AUTH, every waiting wrap) and
/// Background App Refresh did the same with the app closed. Now:
///   - nothing asks a bunker while the app is not in front: the work waits
///     for the next time it is (HomeVaultSender already works this way);
///   - an automatic fetch from the outside relays runs at most every 5 min,
///     in the foreground as in the background;
///   - a wrap the signer refused is not asked about again on its own: only
///     the inbox's Retry asks again.
/// Pure logic, no app types: tested in MediaLogicTests.
enum DMSignerPolicy {
    /// Seconds between two automatic fetches from the outside relays.
    static let fetchGuard: Int64 = 300

    /// May the DM code ask the signer now? A local key never needs a person.
    /// A bunker only while the app is in front, or when the user asked.
    static func mayAskSigner(needsPerson: Bool, appActive: Bool, userAsked: Bool = false) -> Bool {
        !needsPerson || appActive || userAsked
    }

    /// Whether an automatic fetch is due: more than `fetchGuard` seconds
    /// since the last one started.
    static func fetchDue(lastFetch: Int64, now: Int64) -> Bool {
        now - lastFetch > fetchGuard
    }
}

/// Gift wraps the signer refused (or could not open with an error that will
/// not change by asking again). They stay waiting, but only the user's Retry
/// sends them back to the signer: not a refresh, the next foreground, the
/// backoff timer or the relay serving the same wrap again.
struct DMRefusedWraps: Equatable {
    private(set) var ids: Set<String> = []
    /// Refused wraps the user has just asked about again (Retry): each may be
    /// asked once more.
    private var allowed: Set<String> = []

    mutating func refused(_ id: String) {
        ids.insert(id)
        allowed.remove(id)
    }

    /// The signer opened it (or it turned out not to be a chat message).
    mutating func answered(_ id: String) {
        ids.remove(id)
        allowed.remove(id)
    }

    /// Retry: every refused wrap may be asked once more.
    mutating func userAskedAgain() {
        allowed = ids
    }

    /// Whether this wrap may go to the signer now. A refused one only once
    /// after Retry.
    mutating func mayAsk(_ id: String) -> Bool {
        guard ids.contains(id) else { return true }
        return allowed.remove(id) != nil
    }

    func isRefused(_ id: String) -> Bool { ids.contains(id) }

    mutating func reset() {
        self = DMRefusedWraps()
    }
}
