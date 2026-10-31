import Foundation

/// The vault's /private and /chat count sockets, kept open once the owner's
/// AUTH was accepted and a count answered. Each Vault tab visit used to open
/// new ones and sign two NIP-42 AUTHs; a kept socket is still logged in, so
/// the next visit counts on it with no new signature. Keyed by owner and URL,
/// so another owner or relay port never reuses a login that is not theirs.
struct KeptCountSockets<Socket: AnyObject> {
    private var sockets: [String: Socket] = [:]

    private static func key(owner: String, url: URL) -> String {
        owner + "|" + url.absoluteString
    }

    func socket(owner: String, url: URL) -> Socket? {
        sockets[Self.key(owner: owner, url: url)]
    }

    /// Keeps `socket`, and returns the one it replaced (to close it).
    @discardableResult
    mutating func keep(_ socket: Socket, owner: String, url: URL) -> Socket? {
        let replaced = sockets.updateValue(socket, forKey: Self.key(owner: owner, url: url))
        return replaced === socket ? nil : replaced
    }

    /// Forgets `socket` if it is still the one kept (a dead or refused
    /// socket); a newer one kept meanwhile stays.
    mutating func drop(_ socket: Socket, owner: String, url: URL) {
        let key = Self.key(owner: owner, url: url)
        if sockets[key] === socket { sockets[key] = nil }
    }

    /// Forgets `socket` wherever it is kept (it closed).
    mutating func forget(_ socket: Socket) {
        sockets = sockets.filter { $0.value !== socket }
    }
}
