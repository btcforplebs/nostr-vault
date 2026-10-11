import Foundation

extension HavenConfig {
    // MARK: - Mac Relay Derived URLs

    /// Strips any scheme and trailing slashes from macRelayURL to give the bare host[:port]
    var macRelayNormalizedBase: String {
        var url = macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["wss://", "ws://", "https://", "http://"]
        for scheme in schemes {
            if url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count))
            }
        }
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// Always returns the wss:// form of macRelayURL (empty string if macRelayURL is empty)
    var macRelayWssURL: String {
        let base = macRelayNormalizedBase
        return base.isEmpty ? "" : "wss://\(base)"
    }

    /// Always returns the https:// form of macRelayURL (empty string if macRelayURL is empty)
    var macRelayHttpsURL: String {
        let base = macRelayNormalizedBase
        return base.isEmpty ? "" : "https://\(base)"
    }
}
