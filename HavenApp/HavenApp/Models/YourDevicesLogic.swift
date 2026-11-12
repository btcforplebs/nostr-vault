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

// MARK: - The web device (multi-Mac rules §3.3)

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

    /// Which own device is public on the web: the one whose domain is the
    /// first of the owner's https entries in the newest 10063 that is one of
    /// theirs. The list is the one source of truth. `domains`: each own
    /// device's domain (this one's included), by mesh npub. nil: none is.
    static func webDevice(serverList: [String], domains: [String: String]) -> String? {
        let byHost = Dictionary(domains.compactMap { npub, domain in host(domain).map { ($0, npub) } },
                                uniquingKeysWith: { first, _ in first })
        for entry in serverList where entry.lowercased().hasPrefix("https://") {
            if let h = host(entry), let npub = byHost[h] { return npub }
        }
        return nil
    }

    /// Turning Public on the web on asks first when another own device has
    /// it now (Logen's pick 2): "Move public web from <A> to <B>?". nil:
    /// nothing to ask, the switch just turns on.
    static func moveWebPrompt(current: String?, currentName: String, this ownNpub: String, thisName: String) -> String? {
        guard let current, current != ownNpub else { return nil }
        return "Move public web from \(currentName) to \(thisName)?"
    }

    /// The old web device turns its own switch off once it sees lists that
    /// name another own device as the web device. A list that names no own
    /// device (the owner took the domain out by hand) changes nothing here.
    static func standsDown(publicOnWeb: Bool, ownNpub: String, serverList: [String], domains: [String: String]) -> Bool {
        guard publicOnWeb, let web = webDevice(serverList: serverList, domains: domains) else { return false }
        return web != ownNpub
    }

    /// A list of URLs with the old web device's host swapped for `to`, in
    /// place, so its order is kept; `to` goes first when `from` isn't there.
    /// Once only: a second copy of `to` is dropped. Used for 10050 and 10063.
    static func movingWeb(urls: [String], from oldHost: String?, to newURL: String) -> [String] {
        guard let newHost = host(newURL) else { return urls }
        let old = oldHost.flatMap(host)
        var out: [String] = []
        var placed = false
        for url in urls {
            let h = host(url)
            if h == newHost || (old != nil && h == old) {
                if !placed { out.append(newURL); placed = true }
                continue
            }
            out.append(url)
        }
        return placed ? out : [newURL] + out
    }

    /// The same for 10002's `r` tags, keeping each tag's read/write marker.
    static func movingWeb(relayTags: [[String]], from oldHost: String?, to newURL: String) -> [[String]] {
        guard let newHost = host(newURL) else { return relayTags }
        let old = oldHost.flatMap(host)
        var out: [[String]] = []
        var placed = false
        for tag in relayTags {
            guard tag.count >= 2, tag[0] == "r" else { out.append(tag); continue }
            let h = host(tag[1])
            if h == newHost || (old != nil && h == old) {
                if !placed { var moved = tag; moved[1] = newURL; out.append(moved); placed = true }
                continue
            }
            out.append(tag)
        }
        return placed ? out : [["r", newURL]] + out
    }
}
