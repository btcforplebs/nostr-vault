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

    /// The address to use for a configured Blossom server, or nil to skip it.
    ///
    /// nostr.build's website (`nostr.build`, `<name>.nostr.build`) is not a
    /// Blossom server: it answers every upload with its home page. Its Blossom
    /// server is `blossom.nostr.build`, which files the upload under the
    /// uploader's own `<npub>.blossom.band` link, so people who type their
    /// nostr.build address get that server instead of a failed upload.
    /// nostr.band's media server is gone (`blossom.nostr.band` is NXDOMAIN,
    /// `nostr.band` doesn't accept connections — checked 2026-10-16), so it is
    /// skipped rather than timed out on every post.
    static func blossomUploadServer(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URLComponents(string: trimmed)?.host?.lowercased(), !host.isEmpty else { return trimmed }
        if host == "nostr.band" || host.hasSuffix(".nostr.band") { return nil }
        if (host == "nostr.build" || host.hasSuffix(".nostr.build")) && host != "blossom.nostr.build" {
            return "https://blossom.nostr.build"
        }
        return trimmed
    }

    /// Active Blossom mirrors with optional FIPS URL appended last (clearnet-first per BUD-14).
    func activeBlossomMirrors(detectedNpub: String? = nil) -> [String] {
        var mirrors: [String] = []
        for configured in blossomMirrors {
            if let server = Self.blossomUploadServer(configured), !mirrors.contains(server) {
                mirrors.append(server)
            }
        }
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

    /// Where a delete of one of the owner's files goes: the configured
    /// mirrors, the owner's server list (kind 10063) and the server in the
    /// photo's own link, once each. A file can sit on a server this device
    /// never uploaded to (the home vault passes uploads on to the 10063
    /// list), so deleting from the configured mirrors alone left it public.
    /// `includeHomeVault` false is "Delete from mirrors": the Mac relay and
    /// the FIPS address keep their copy.
    func blossomDeleteTargets(ownerServerList: [String], photoURL: URL?, includeHomeVault: Bool,
                              detectedNpub: String? = nil) -> [String] {
        var candidates = activeBlossomMirrors(detectedNpub: detectedNpub)
        candidates += ownerServerList.compactMap(Self.blossomUploadServer)
        if let photoServer = Self.blossomServerOrigin(of: photoURL),
           let server = Self.blossomUploadServer(photoServer) {
            candidates.append(server)
        }
        let homeVault = Set([macRelayHttpsURL, fipsBlossomURL(detectedNpub: detectedNpub) ?? ""]
            .filter { !$0.isEmpty }.map(Self.blossomServerKey))
        var seen = Set<String>()
        var targets: [String] = []
        for server in candidates {
            let key = Self.blossomServerKey(server)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            if !includeHomeVault && homeVault.contains(key) { continue }
            targets.append(server)
        }
        return targets
    }

    /// `scheme://host[:port]` of a photo link on an outside server, or nil
    /// for this device's own relay (loopback) and mesh (.fips) links: those
    /// copies are the local and home-vault ones, deleted on their own.
    static func blossomServerOrigin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".fips") { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// One server however it was typed: case, trailing slashes and http vs
    /// https (deletes go over https anyway) don't make a second server.
    static func blossomServerKey(_ server: String) -> String {
        var key = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("http://") { key = "https://" + key.dropFirst("http://".count) }
        while key.hasSuffix("/") { key.removeLast() }
        return key
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
