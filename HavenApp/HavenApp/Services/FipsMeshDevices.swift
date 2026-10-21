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
        let owner = NostrService.shared.activeHexPubkey
        let home = HomeVaultSender.shared.homeVault.flatMap { $0.ownerHex == owner ? $0.meshNpub : nil }
        return MeshDevicesLogic.merged(
            stored: config.meshDevices,
            macNpub: config.macRelayMeshNpub,
            homeVaultNpub: home,
            browserNpub: BrowserRelaySender.shared.relay?.meshNpub
        )
    }

    /// Adds `device`, or says in plain words why it can't. `address` is what
    /// was pasted or scanned: an npub, `nostr:npub…` or `fipsmesh://npub…/`.
    static func add(address: String, name: String, role: MeshDeviceRole, config: ConfigService) -> String? {
        guard let npub = HomeVaultLogic.meshNpub(fromInput: address) else {
            return "That isn't a mesh address. Copy it from FIPS Mesh → This Device on the other device."
        }
        if let own = FipsMeshService.shared.ownMeshNpub ?? FipsMeshService.meshNpubFromKey(), npub == own {
            return "That is this phone's own address."
        }
        let owner = NostrService.shared.activeHexPubkey
        switch role {
        case .mac:
            let typed = config.config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, config.config.macRelayMeshNpub == nil {
                return "Your Mac is set by its web address in Sync with Vault on Mac. Clear it there first, then add it here."
            }
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
        // The same address under another role leaves that role's setting.
        if let old = current(config.config).first(where: { $0.npub == npub }), old.role != role {
            clearSetting(for: old, config: config)
        }
        let device = MeshDevice(npub: npub, name: name.trimmingCharacters(in: .whitespacesAndNewlines), role: role)
        config.config.meshDevices = MeshDevicesLogic.adding(device, to: config.config.meshDevices)
        config.save()
        return nil
    }

    static func rename(_ device: MeshDevice, to name: String, config: ConfigService) {
        var renamed = device
        renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.config.meshDevices = MeshDevicesLogic.adding(renamed, to: config.config.meshDevices)
        config.save()
    }

    static func remove(_ device: MeshDevice, config: ConfigService) {
        clearSetting(for: device, config: config)
        config.config.meshDevices = MeshDevicesLogic.removing(npub: device.npub, from: config.config.meshDevices)
        config.save()
    }

    private static func clearSetting(for device: MeshDevice, config: ConfigService) {
        switch device.role {
        case .mac:
            if config.config.macRelayMeshNpub == device.npub { config.config.macRelayURL = "" }
        case .homeVault:
            if HomeVaultSender.shared.homeVault?.meshNpub == device.npub { HomeVaultSender.shared.setHomeVault(nil) }
        case .browser:
            if BrowserRelaySender.shared.relay?.meshNpub == device.npub { BrowserRelaySender.shared.setRelay(nil) }
        case .phone:
            break
        }
    }
}
#endif
