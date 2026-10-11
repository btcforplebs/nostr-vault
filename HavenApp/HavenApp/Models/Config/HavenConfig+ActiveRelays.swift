import Foundation

extension HavenConfig {
    // MARK: - Blossom Mirrors Configuration

    /// Builds the .fips Blossom URL from the configured source, or nil if FIPS publishing is disabled.
    func fipsBlossomURL(detectedNpub: String? = nil) -> String? {
        guard fipsPublishEnabled else { return nil }
        let npub: String
        switch fipsAddressSource {
        case "detected":
            guard let detected = detectedNpub, !detected.isEmpty else { return nil }
            npub = detected
        case "custom":
            npub = fipsCustomNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            npub = ownerNpub
        }
        let clean = npub.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("npub1") else { return nil }
        return "http://\(clean).fips:\(relayPort)"
    }

    /// Active Blossom mirrors with optional FIPS URL appended last (clearnet-first per BUD-14).
    func activeBlossomMirrors(detectedNpub: String? = nil) -> [String] {
        var mirrors = blossomMirrors
        let macHttps = macRelayHttpsURL
        if !macHttps.isEmpty, !mirrors.contains(macHttps) {
            mirrors.insert(macHttps, at: 0)
        }
        if let fipsURL = fipsBlossomURL(detectedNpub: detectedNpub), !mirrors.contains(fipsURL) {
            mirrors.append(fipsURL)
        }
        return mirrors
    }

    /// Active Blossom mirrors (convenience, no detected FIPS npub).
    var activeBlossomMirrors: [String] {
        activeBlossomMirrors(detectedNpub: nil)
    }

    /// Active feed relays, including the Mac relay if configured.
    var activeFeedRelays: [String] {
        var relays = feedRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }

    /// Active blastr relays, including the Mac relay if configured.
    var activeBlastrRelays: [String] {
        var relays = blastrRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }

    /// Active import seed relays, including the Mac relay if configured.
    var activeImportSeedRelays: [String] {
        var relays = importSeedRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }
}
