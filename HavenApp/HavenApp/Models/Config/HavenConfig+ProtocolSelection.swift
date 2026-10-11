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
        guard !isLocal, !Self.isPrivateNetworkHost(sanitizedRelayURL) else { return "" }
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
