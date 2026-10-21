import Foundation

extension HavenConfig {
    // MARK: - Mac Relay Derived URLs

    /// The Mac's mesh npub when the Mac relay field holds one (`npub1…`,
    /// `nostr:npub1…` or `fipsmesh://npub1…/`) instead of a URL; nil otherwise.
    /// The relay reaches that Mac through FIPS (RelayConfiguration.macMeshRelay).
    var macRelayMeshNpub: String? {
        HomeVaultLogic.meshNpub(fromInput: macRelayURL)
    }

    /// Strips any scheme and trailing slashes from macRelayURL to give the bare host[:port].
    /// Empty for a mesh npub: that Mac has no address anyone else can use.
    var macRelayNormalizedBase: String {
        guard macRelayMeshNpub == nil else { return "" }
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
