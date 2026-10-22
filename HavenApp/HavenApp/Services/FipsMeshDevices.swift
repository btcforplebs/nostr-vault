#if os(iOS)
import Foundation

/// My Devices on iPhone. The list is `config.meshDevices`, kept in step with
/// the settings that already name a device: the Mac by its mesh address
/// (`macRelayURL`), the home vault (HomeVaultSender) and the browser page
/// (BrowserRelaySender). Adding or removing one of those changes that setting,
/// so the senders keep working from their own source of truth.
@MainActor
enum FipsMeshDevices {
    static func current(_ config: HavenConfig) -> [MeshDevice] {
        let sources = sources(config)
        return MeshDevicesLogic.merged(
            stored: config.meshDevices,
            macNpub: sources.mac,
            homeVaultNpub: sources.home,
            browserNpub: sources.browser
        )
    }

    /// The address each setting names for this account. A home vault or
    /// browser page set up under another account isn't this account's device.
    private static func sources(_ config: HavenConfig) -> (mac: String?, home: String?, browser: String?) {
        let owner = NostrService.shared.activeHexPubkey
        let home = HomeVaultSender.shared.homeVault.flatMap { $0.ownerHex == owner ? $0.meshNpub : nil }
        let browser = BrowserRelaySender.shared.relay.flatMap { $0.ownerHex == owner ? $0.meshNpub : nil }
        return (config.macRelayMeshNpub, home, browser)
    }

    private static func rolesNaming(_ npub: String, config: HavenConfig) -> [MeshDeviceRole] {
        let sources = sources(config)
        return MeshDevicesLogic.rolesNaming(npub, macNpub: sources.mac, homeVaultNpub: sources.home, browserNpub: sources.browser)
    }

    /// Adds `device`, or says in plain words why it can't. `address` is what
    /// was pasted or scanned: an npub, `nostr:npub…` or `fipsmesh://npub…/`.
    static func add(address: String, name: String, role: MeshDeviceRole, config: ConfigService) -> String? {
        let before = current(config.config)
        guard let npub = HomeVaultLogic.meshNpub(fromInput: address) else {
            return "That isn't a mesh address. Copy it from FIPS Mesh → This Device on the other device."
        }
        if let own = FipsMeshService.shared.ownMeshNpub ?? FipsMeshService.meshNpubFromKey(), npub == own {
            return "That is this phone's own address."
        }
        if role == .mac {
            let typed = config.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, config.config.macRelayMeshNpub == nil {
                return "Your Mac is set by its web address in Sync with Vault on Mac. Clear it there first, then add it here."
            }
        }
        // One address, one role: the same address under another role leaves
        // that role's setting first, so only the new one sends to it.
        for old in rolesNaming(npub, config: config.config) where old != role {
            clearSetting(old, npub: npub, config: config)
        }
        let owner = NostrService.shared.activeHexPubkey
        let device = MeshDevice(npub: npub, name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
        // Before the setting changes: a new home vault republishes the 10063,
        // and the old one must already be a plain device by then to stay listed.
        config.config.meshDevices = MeshDevicesLogic.adding(device, to: config.config.meshDevices)
        switch role {
        case .mac:
            config.config.macRelayURL = npub
        case .homeVault:
            HomeVaultSender.shared.setHomeVault(.init(ownerHex: owner, meshNpub: npub))
        case .browser:
            BrowserRelaySender.shared.setRelay(.init(ownerHex: owner, meshNpub: npub))
            // Start (or restart) the engine with the relay link, so the page can find this phone.
            Task { _ = await FipsMeshService.shared.connectForBrowserRelay() }
        case .phone:
            break
        }
        config.save()
        // The Mac is listed in the 10063 by this phone (HomeVaultLogic.phoneMeshEntries).
        if role == .mac { NostrService.shared.publishServerList() }
        FipsMeshService.shared.myDevicesChanged(from: before)
        return nil
    }

    static func rename(_ device: MeshDevice, to name: String, config: ConfigService) {
        var renamed = device
        renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.config.meshDevices = MeshDevicesLogic.adding(renamed, to: config.config.meshDevices)
        config.save()
    }

    static func remove(_ device: MeshDevice, config: ConfigService) {
        let before = current(config.config)
        let roles = rolesNaming(device.npub, config: config.config)
        for role in roles {
            clearSetting(role, npub: device.npub, config: config)
        }
        let listedBefore = NostrService.serverListManaged(owner: NostrService.shared.activeHexPubkey)
        let wasListed = !HomeVaultLogic.stillOwnedMeshEntries(previouslyManaged: listedBefore, myDevices: [device.npub]).isEmpty
        config.config.meshDevices = MeshDevicesLogic.removing(npub: device.npub, from: config.config.meshDevices)
        config.save()
        // The Mac, or an old home vault kept listed as a plain device: unlist
        // it now. A home vault's own setting change already republished.
        if roles.contains(.mac) || (wasListed && roles.isEmpty) { NostrService.shared.publishServerList() }
        // A lost phone's mesh key stops reaching this one's vault now, not
        // at the next kiosk start (NIP-F1 revoke).
        FipsMeshService.shared.myDevicesChanged(from: before)
    }

    private static func clearSetting(_ role: MeshDeviceRole, npub: String, config: ConfigService) {
        switch role {
        case .mac:
            if config.config.macRelayMeshNpub == npub { config.config.macRelayURL = "" }
        case .homeVault:
            if HomeVaultSender.shared.homeVault?.meshNpub == npub { HomeVaultSender.shared.setHomeVault(nil) }
        case .browser:
            if BrowserRelaySender.shared.relay?.meshNpub == npub { BrowserRelaySender.shared.setRelay(nil) }
        case .phone:
            break
        }
    }
}
#endif
