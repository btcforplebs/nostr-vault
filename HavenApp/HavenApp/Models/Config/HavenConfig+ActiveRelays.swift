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
    /// `includeHomeVault` false is "Delete from mirrors": no home-network or
    /// mesh server is a target (LAN, `.local`, `.fips`, `fipsmesh://`, the
    /// configured Mac and FIPS address), since any of them may be one of the
    /// owner's vaults. A vault with a public https name (another phone's Mac
    /// in 10063) looks like a mirror here; `vaultCheckVerdict` catches it
    /// before the delete is sent.
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
            if !includeHomeVault && (homeVault.contains(key) || Self.isHomeNetworkServer(server)) { continue }
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

    /// One server however it was typed: case, trailing slashes, http vs
    /// https (deletes go over https anyway) and a spelled-out default port
    /// don't make a second server.
    static func blossomServerKey(_ server: String) -> String {
        var key = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("http://") { key = "https://" + key.dropFirst("http://".count) }
        while key.hasSuffix("/") { key.removeLast() }
        for port in [":443", ":80"] where key.hasSuffix(port) { key.removeLast(port.count) }
        return key
    }

    /// A server only the owner's own devices can be on: a mesh entry or
    /// address, or a home-network host (LAN IP, `.local`, `.lan`, `.ts.net`,
    /// loopback). Those are vault addresses, never a public mirror.
    static func isHomeNetworkServer(_ server: String) -> Bool {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HomeVaultLogic.isReachableWithoutMesh(trimmed),
              let host = URLComponents(string: trimmed)?.host, !host.isEmpty else { return true }
        return isPrivateNetworkHost(host)
    }

    /// What a server's NIP-11 answer says about deleting from it with
    /// "Delete from mirrors".
    enum VaultCheckVerdict: Equatable {
        /// Not one of the owner's vaults: delete there.
        case mirror
        /// A Haven relay run by the owner: one of their vaults, keep its copy.
        case ownVault
        /// No answer: it may be a vault, so nothing is sent there.
        case unknown
    }

    /// `info` is the body a server sent back for `Accept:
    /// application/nostr+json` at its root, or nil when it didn't answer.
    /// Every vault's relay names its owner as `pubkey` (OUTBOX_RELAY_NPUB),
    /// whatever address it is reached by, so this catches a vault listed
    /// under a name this device has never seen. Public media servers answer
    /// with a page, an error or someone else's key.
    static func vaultCheckVerdict(info: Data?, ownerHex: String) -> VaultCheckVerdict {
        guard let info else { return .unknown }
        guard let object = try? JSONSerialization.jsonObject(with: info) as? [String: Any],
              let pubkey = object["pubkey"] as? String else { return .mirror }
        let owner = ownerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !owner.isEmpty else { return .unknown }
        return pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == owner ? .ownVault : .mirror
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
