import Foundation

/// The NIP-42 order VaultSocket keeps with this device's vault: send on
/// connect, answer the first challenge, and after an AUTH send the request
/// again only once the vault's OK for that AUTH arrives. The vault handles
/// each message on its own goroutine, so a REQ sent right behind the AUTH is
/// checked before the AUTH lands and comes back `auth-required`. One
/// `auth-required` refusal after the OK gets one retry. Pure, so it is
/// tested in MediaLogicTests.
struct VaultAuthGate {
    enum Action: Equatable {
        /// Not about auth: hand it to the caller's reader.
        case pass
        /// Auth bookkeeping only.
        case ignore
        /// Send the request (again).
        case start
        /// Give up: the vault refused us.
        case fail
    }

    private(set) var challenged = false
    private(set) var authId: String?
    private(set) var authed = false
    private(set) var retried = false

    /// True for the first challenge only: sign that one.
    mutating func challenge() -> Bool {
        guard !challenged else { return false }
        challenged = true
        return true
    }

    mutating func sentAuth(id: String) { authId = id }

    /// What to do with one message from the vault (`arr` is the decoded
    /// JSON array, `type` its first element). AUTH challenges are handled
    /// before this by `challenge()`.
    mutating func handle(type: String, _ arr: [Any]) -> Action {
        if type == "OK", let authId, arr.count > 1, arr[1] as? String == authId {
            guard (arr.count > 2 ? arr[2] as? Bool : nil) == true else { return .fail }
            authed = true
            return .start
        }
        guard Self.isAuthRequired(type: type, arr) else { return .pass }
        // Before the AUTH's OK: the request goes again when the OK comes.
        guard authed else { return .ignore }
        guard !retried else { return .fail }
        retried = true
        return .start
    }

    /// A CLOSED or a refused OK whose reason starts with `auth-required`.
    static func isAuthRequired(type: String, _ arr: [Any]) -> Bool {
        switch type {
        case "CLOSED":
            return (arr.count > 2 ? arr[2] as? String : nil)?.hasPrefix("auth-required") ?? false
        case "OK":
            let accepted = (arr.count > 2 ? arr[2] as? Bool : nil) ?? false
            return !accepted && ((arr.count > 3 ? arr[3] as? String : nil)?.hasPrefix("auth-required") ?? false)
        default:
            return false
        }
    }
}
