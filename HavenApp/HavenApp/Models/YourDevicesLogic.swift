import Foundation

/// Pure rules for Settings › Your Devices, kept out of the view for tests.
enum YourDevicesLogic {
    /// Which Sync now a device's card gets.
    enum SyncAction: Equatable {
        /// The desktop vault's sync check (the Mac slot's copy and check).
        case desktopVault
        /// Send what waits for the mobile vault.
        case mobileVault
    }

    /// A desktop vault gets the sync check only while the phone has a Mac set
    /// (the check runs against that Mac); a mobile vault only when it is the
    /// one this phone sends to. Phones and browser vaults get none.
    static func syncAction(_ device: MeshDevice, macSet: Bool, homeVaultNpub: String?) -> SyncAction? {
        switch device.role {
        case .mac: return macSet ? .desktopVault : nil
        case .homeVault: return device.npub == homeVaultNpub ? .mobileVault : nil
        case .phone, .browser: return nil
        }
    }

    /// The card's second line: its role, and whether this device is
    /// connected to it now. `peers` nil: the mesh is not running, so only
    /// the role is known.
    static func statusLine(_ device: MeshDevice, peers: Set<String>?) -> String {
        guard let peers else { return device.role.label }
        return peers.contains(device.npub)
            ? "\(device.role.label) · in reach"
            : "\(device.role.label) · not in reach now"
    }
}

// MARK: - Full copy (multi-Mac rules §3)

extension YourDevicesLogic {
    /// Whether this device keeps every own note and file. Macs and boxes
    /// always do; a mobile vault always does; a phone unless its owner
    /// turned the switch off. Unset (new and existing phones) is on: Logen's
    /// pick 1 (2026-11-12) — a file on any device shows up on all the others.
    static func keepsFullCopy(isDesktop: Bool, mobileVault: Bool, stored: Bool?) -> Bool {
        isDesktop || mobileVault || stored != false
    }

    /// The switch is shown but can't be turned off: a mobile vault keeps
    /// everything. Macs and boxes show a label instead of a switch.
    static func fullCopyLocked(mobileVault: Bool) -> Bool { mobileVault }

    static let fullCopyLockedLine = "A mobile vault keeps everything."

    /// Whether a catch-up moves files, not only notes (rule 7): a light
    /// device never does; a full-copy phone only on Wi-Fi while Wi-Fi only is
    /// on (the default). Its own new media goes out at once regardless.
    static func catchUpMovesFiles(fullCopy: Bool, isDesktop: Bool, wifiOnly: Bool?, onWiFi: Bool) -> Bool {
        guard fullCopy else { return false }
        if isDesktop { return true }
        return onWiFi || wifiOnly == false
    }
}

// MARK: - Public on the web (Desktop Vaults §2.5 rule 3)

extension YourDevicesLogic {
    /// The host of an `https://`/`wss://` URL or a bare domain, lowercased,
    /// without port or path. nil for anything without a host.
    static func host(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let host = URL(string: t)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// Every own device whose domain is one of the https entries in the
    /// owner's newest 10063: each gets a "Public on the web" mark. Any number
    /// may be listed at once; there is no single web device any more.
    /// `domains`: each own device's domain, by mesh npub.
    static func publicOnWeb(serverList: [String], domains: [String: String]) -> Set<String> {
        let listed = Set(serverList.filter { $0.lowercased().hasPrefix("https://") }.compactMap(host))
        return Set(domains.compactMap { npub, domain in host(domain).flatMap { listed.contains($0) ? npub : nil } })
    }
}
