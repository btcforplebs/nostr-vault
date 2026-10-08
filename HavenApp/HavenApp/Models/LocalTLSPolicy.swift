import Foundation

/// Which TLS rule applies to a host, and whether a pinned certificate
/// matches. Pure, so it is unit-tested; `LocalTLSTrust` applies it.
enum LocalTLSPolicy {
    enum Kind: Equatable {
        /// This device: trusted as is.
        case loopback
        /// A private address or an mDNS `.local` name: pinned on first use.
        case lan
        /// Everything else: the system's normal certificate check.
        case `public`
    }

    static func kind(of host: String?) -> Kind {
        guard var host = host?.lowercased(), !host.isEmpty else { return .public }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) { return .loopback }
        if host.hasSuffix(".local") { return .lan }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return .public }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return .public }
        switch (octets[0], octets[1]) {
        case (10, _): return .lan
        case (172, 16...31): return .lan
        case (192, 168): return .lan
        case (127, _): return .loopback
        default: return .public
        }
    }

    enum Decision: Equatable {
        case acceptAndPin, accept, reject
    }

    /// First sight pins the certificate; after that only the same one passes.
    static func decide(pinned: String?, presented: String) -> Decision {
        guard let pinned else { return .acceptAndPin }
        return pinned == presented ? .accept : .reject
    }
}

/// The saved certificate per LAN relay (host:port → SHA-256 of the leaf) and
/// the relays refused this session because theirs changed. Storage is passed
/// in, so the save → refuse → Trust New sequence is unit-tested; the app
/// keeps it in UserDefaults (`LocalTLSTrust`).
final class LocalTLSPins {
    private let load: () -> [String: String]
    private let save: ([String: String]?) -> Void
    private let lock = NSLock()
    private var refused: Set<String> = []

    /// `save(nil)` removes the stored pins.
    init(load: @escaping () -> [String: String], save: @escaping ([String: String]?) -> Void) {
        self.load = load
        self.save = save
    }

    enum Outcome: Equatable {
        case accepted
        /// Refused; `firstTime` is true the first time this session.
        case refused(firstTime: Bool)
    }

    func check(_ hostPort: String, fingerprint: String) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        var pins = load()
        switch LocalTLSPolicy.decide(pinned: pins[hostPort], presented: fingerprint) {
        case .acceptAndPin:
            pins[hostPort] = fingerprint
            save(pins)
            return .accepted
        case .accept:
            return .accepted
        case .reject:
            return .refused(firstTime: refused.insert(hostPort).inserted)
        }
    }

    var refusedHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return refused.sorted()
    }

    /// Trust New: forgets `hostPort`'s certificate; the next one is saved.
    func forget(_ hostPort: String) {
        lock.lock(); defer { lock.unlock() }
        var pins = load()
        pins[hostPort] = nil
        save(pins)
        refused.remove(hostPort)
    }

    /// Reset App: forgets every certificate.
    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        save(nil)
        refused.removeAll()
    }
}
