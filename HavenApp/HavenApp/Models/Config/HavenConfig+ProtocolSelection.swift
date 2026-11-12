import Foundation

extension HavenConfig {
    // MARK: - Protocol Selection Logic

    /// Returns the relay URL without any protocol schemes or trailing slashes
    var sanitizedRelayURL: String {
        var url = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["wss://", "ws://", "https://", "http://"]
        for scheme in schemes {
            if url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count))
            }
        }
        while url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        return url
    }
    
    /// Returns true if the relay is running locally (empty URL, localhost, or 127.0.0.1)
    var isLocal: Bool {
        let url = sanitizedRelayURL.lowercased()
        if url.isEmpty { return true }
        
        // Split by colon to ignore port
        let host = url.split(separator: ":").first.map(String.init) ?? url
        return host == "localhost" || host == "127.0.0.1"
    }
    
    /// This relay's own domain may go in lists and hints other people read:
    /// it has an address and the owner has not turned Public on the web off.
    /// Turning it off stops the listing only; the domain still serves. nil
    /// (never touched) keeps today's behaviour: a domain is listed. Callers
    /// keep their own private-network check.
    var listsOwnDomain: Bool {
        !isLocal && (publicOnWeb ?? true)
    }

    /// This vault's own web host as told to the owner's other devices over
    /// the mesh (WEB_DOMAIN_PROOF, multi-Mac rules §3.3): the host without port,
    /// whether or not Public on the web is on, so another Mac can offer
    /// "make this one public instead". "" when it has none the world can
    /// reach (local, a home address, an IP): mesh-only Macs send nothing.
    /// The engine checks again. Only the Mac passes it; phones never serve.
    var webDomainForOwnDevices: String {
        guard !isLocal else { return "" }
        let hostPort = sanitizedRelayURL.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        // A bracketed or bare IPv6 address has more than one colon: never sent.
        guard hostPort.filter({ $0 == ":" }).count <= 1 else { return "" }
        let host = hostPort.split(separator: ":").first.map(String.init) ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.contains("."), host.allSatisfy({ allowed.contains($0) }),
              !host.allSatisfy({ $0.isNumber || $0 == "." }), // an IPv4 address
              !Self.isPrivateNetworkHost(host) else { return "" }
        return host
    }

    /// Returns the appropriate WebSocket URL (ws:// for local, wss:// for remote)
    var nostrURL: String {
        if isLocal {
            #if os(macOS)
            return "ws://127.0.0.1:\(relayPort)"
            #else
            return "wss://127.0.0.1:\(relayPort)"
            #endif
        } else {
            return "wss://\(sanitizedRelayURL)"
        }
    }

    /// The relay to name in a tag's relay hint for other clients: this relay
    /// when the world can reach it, otherwise none. A loopback or home-network
    /// address points every other client at itself, or at nothing.
    var publicRelayHint: String {
        guard listsOwnDomain, !Self.isPrivateNetworkHost(sanitizedRelayURL) else { return "" }
        return nostrURL
    }

    /// Returns the appropriate Web/Blossom URL (https:// on iOS for Blossom, http:// on macOS)
    var webURL: String {
        if isLocal {
            #if os(macOS)
            return "http://127.0.0.1:\(relayPort)"
            #else
            return "https://127.0.0.1:\(relayPort)"
            #endif
        } else {
            return "https://\(sanitizedRelayURL)"
        }
    }
}
