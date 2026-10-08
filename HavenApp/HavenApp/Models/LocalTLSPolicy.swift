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
