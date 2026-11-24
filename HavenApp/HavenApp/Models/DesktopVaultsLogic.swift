import CryptoKit
import Foundation

/// The desktop Vault list: migration from the one-slot `macRelayURL`, the
/// addresses the relay and the derived relay lists get, and the engine's
/// per-Vault status file name (PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.1, §3).
/// Pure, so MediaLogicTests checks it on docs/fixtures/desktop-vaults.
/// Android twin: `relay/DesktopVaultsRules.kt`.
enum DesktopVaultsLogic {

    /// A Vault's id, made from the address it was first made with, so the
    /// same Vault made on two devices gets the same id.
    static func id(httpsHost: String) -> String { "https:\(httpsHost)" }
    static func id(meshNpub: String) -> String { "mesh:\(meshNpub)" }

    /// `https://<base>` for a typed web address, nil for anything else.
    /// The base is kept as typed but for the scheme and trailing slashes,
    /// exactly as the slot's (HavenConfig.macRelayNormalizedBase), so the
    /// relay lists get the same address they did.
    static func httpsURL(_ raw: String) -> String? {
        guard HomeVaultLogic.meshNpub(fromInput: raw) == nil, DesktopVaultsLists.hostKey(raw) != nil else { return nil }
        return "https://\(base(raw))"
    }

    /// The address without its scheme and trailing slashes.
    static func base(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["wss://", "ws://", "https://", "http://"] where url.lowercased().hasPrefix(scheme) {
            url = String(url.dropFirst(scheme.count))
            break
        }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// The Vaults with `order` renumbered 0, 1, 2… in their current order
    /// (ties by id, §2.6).
    static func ordered(_ vaults: [DesktopVault]) -> [DesktopVault] {
        vaults.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
            .enumerated().map { i, vault in
                var vault = vault
                vault.order = i
                return vault
            }
    }

    // MARK: Migration (§3) and the old tab

    /// The Vault list after taking in the one-slot setting.
    ///
    /// `taken` is the slot value the list last took in, nil when it never
    /// has. The first time (§3), with no Vaults yet:
    /// 1. a slot holding a mesh npub becomes a FIPS-only Vault;
    /// 2. a slot holding a web address becomes an HTTPS-only Vault, merged
    ///    with the owner's `.mac` device whose `domain` has that host;
    /// 3. every other `.mac` device becomes a FIPS-only Vault, in `macs()`
    ///    order after the slot's.
    /// Nothing is published and `macRelayURL` is never written (§3 steps 4-5).
    ///
    /// Until the Desktop Vaults screens replace the old Desktop vault sync
    /// tab (P4), that tab still edits the slot, so a later change to it moves
    /// the Vault that came from the old value. Only that Vault's slot address
    /// changes; every other Vault stays as it is.
    static func takingInSlot(_ vaults: [DesktopVault], slot: String, taken: String?,
                             devices: [MeshDevice], ownNpub: String? = nil) -> [DesktopVault] {
        guard let taken else {
            return vaults.isEmpty ? migrated(slot: slot, devices: devices, ownNpub: ownNpub) : ordered(vaults)
        }
        let old = SlotAddress(taken), new = SlotAddress(slot)
        guard old != new else { return vaults }
        var out = ordered(vaults)
        // The old address leaves the Vault that had it.
        switch old {
        case .web(let host):
            if let i = out.firstIndex(where: { $0.hostKey == host }) { out[i].httpsURL = nil }
        case .mesh(let npub):
            if let i = out.firstIndex(where: { $0.meshNpub == npub }), out[i].httpsURL == nil,
               !devices.contains(where: { $0.npub == npub && $0.role == .mac }) {
                out[i].meshNpub = nil
            }
        case .none:
            break
        }
        out.removeAll { $0.meshNpub == nil && $0.httpsURL == nil }
        // The new one goes to the Vault that has it, else to the `.mac`
        // device whose domain or npub it is, else to a new Vault, first.
        switch new {
        case .web(let host):
            guard !out.contains(where: { $0.hostKey == host }) else { break }
            if let device = macDevice(domain: host, devices: devices, ownNpub: ownNpub),
               let i = out.firstIndex(where: { $0.meshNpub == device.npub }) {
                out[i].httpsURL = httpsURL(slot)
            } else {
                out.insert(vaultForSlot(new, typed: slot, devices: devices, ownNpub: ownNpub), at: 0)
            }
        case .mesh(let npub):
            guard npub != ownNpub, !out.contains(where: { $0.meshNpub == npub }) else { break }
            out.insert(vaultForSlot(new, typed: slot, devices: devices, ownNpub: ownNpub), at: 0)
        case .none:
            break
        }
        return out.enumerated().map { i, vault in
            var vault = vault
            vault.order = i
            return vault
        }
    }

    static func migrated(slot: String, devices: [MeshDevice], ownNpub: String?) -> [DesktopVault] {
        var out: [DesktopVault] = []
        let address = SlotAddress(slot)
        if case .mesh(let npub) = address, npub == ownNpub {
            // This device's own address: never a Vault of its own.
        } else if address != .none {
            out.append(vaultForSlot(address, typed: slot, devices: devices, ownNpub: ownNpub))
        }
        let slotNpub: String? = { if case .mesh(let npub) = address { return npub } else { return nil } }()
        for npub in MeshDevicesLogic.macs(devices, macNpub: slotNpub, ownNpub: ownNpub)
            where !out.contains(where: { $0.meshNpub == npub }) {
            let device = devices.first { $0.npub == npub }
            out.append(DesktopVault(id: id(meshNpub: npub), name: device?.name ?? "", meshNpub: npub, order: 0))
        }
        return out.enumerated().map { i, vault in
            var vault = vault
            vault.order = i
            return vault
        }
    }

    /// What the slot holds: a web host, a mesh npub or nothing.
    enum SlotAddress: Equatable {
        case none
        case web(String)
        case mesh(String)

        init(_ raw: String) {
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self = .none
            } else if let npub = HomeVaultLogic.meshNpub(fromInput: raw) {
                self = .mesh(npub)
            } else if let host = DesktopVaultsLists.hostKey(raw) {
                self = .web(host)
            } else {
                self = .none
            }
        }
    }

    private static func macDevice(domain host: String, devices: [MeshDevice], ownNpub: String?) -> MeshDevice? {
        devices.first { device in
            device.role == .mac && device.npub != ownNpub
                && device.domain.flatMap(DesktopVaultsLists.hostKey) == host
        }
    }

    private static func vaultForSlot(_ address: SlotAddress, typed: String, devices: [MeshDevice],
                                     ownNpub: String?) -> DesktopVault {
        switch address {
        case .web(let host):
            if let device = macDevice(domain: host, devices: devices, ownNpub: ownNpub) {
                return DesktopVault(id: id(meshNpub: device.npub), name: device.name, meshNpub: device.npub,
                                    httpsURL: httpsURL(typed), order: 0)
            }
            return DesktopVault(id: id(httpsHost: host), name: "", httpsURL: httpsURL(typed), order: 0)
        case .mesh(let npub):
            let device = devices.first { $0.npub == npub }
            return DesktopVault(id: id(meshNpub: npub), name: device?.name ?? "", meshNpub: npub, order: 0)
        case .none:
            return DesktopVault(id: "", name: "", order: 0)
        }
    }

    // MARK: Addresses the relay and the derived lists get

    /// Every HTTPS Vault's `wss://<base>`, in list order, one per host.
    static func wssURLs(_ vaults: [DesktopVault]) -> [String] {
        bases(vaults).map { "wss://\($0.base)" }
    }

    /// Every HTTPS Vault's `https://<base>`, in list order, one per host.
    static func httpsURLs(_ vaults: [DesktopVault]) -> [String] {
        bases(vaults).map { "https://\($0.base)" }
    }

    private static func bases(_ vaults: [DesktopVault]) -> [(host: String, base: String)] {
        var seen = Set<String>()
        return ordered(vaults).compactMap { vault in
            guard let url = vault.httpsURL, let host = vault.hostKey, seen.insert(host).inserted else { return nil }
            return (host, base(url))
        }
    }

    /// DESKTOP_VAULT_URLS for the relay (haven-go macsync.go): every HTTPS
    /// Vault but the one MAC_RELAY_URL already names, comma separated, ""
    /// when there is none. Always passed, empty included, because the engine
    /// never clears a host env key (Tidy, P1).
    static func envList(_ vaults: [DesktopVault], slot: String) -> String {
        let slotHost: String? = { if case .web(let host) = SlotAddress(slot) { return host } else { return nil } }()
        return bases(vaults).filter { $0.host != slotHost }.map { "wss://\($0.base)" }.joined(separator: ",")
    }

    // MARK: Engine status files

    /// The engine's per-Vault status file for `base` (haven-go
    /// macSyncStatusFile): the URL with the scheme kept, `://` as `_` and
    /// anything but letters, digits, `.` and `-` as `_`; a name over 200
    /// bytes is the SHA-256 hex of `base`.
    static func statusFileName(base: String) -> String {
        var name = base
        if let range = name.range(of: "://") { name.replaceSubrange(range, with: "_") }
        name = String(name.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let keep = scalar == "." || scalar == "-" || (48...57).contains(v) || (65...90).contains(v) || (97...122).contains(v)
            return keep ? Character(scalar) : "_"
        })
        if name.utf8.count > 200 {
            name = SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return "mac_sync_status-\(name).json"
    }
}
