import Foundation

/// What one of the owner's own devices is to this one. The same four roles,
/// with the same labels, on iPhone, Android and Mac.
enum MeshDeviceRole: String, Codable, CaseIterable, Identifiable {
    case mac
    case phone
    case homeVault
    case browser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac: return "Vault on Mac"
        case .phone: return "Phone"
        case .homeVault: return "Home vault"
        case .browser: return "Browser page"
        }
    }

    var icon: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .phone: return "iphone"
        case .homeVault: return "house"
        case .browser: return "globe"
        }
    }

    /// What this device does for you, in one line.
    var job: String {
        switch self {
        case .mac: return "Keeps your full history. Syncs both ways."
        case .phone: return "Another phone of yours on the mesh."
        case .homeVault: return "Gets your new notes and media, and sends your notes on."
        case .browser: return "Gets your new notes while this app is open."
        }
    }
}

/// One entry in My Devices: a mesh address, a name and a role.
struct MeshDevice: Codable, Hashable, Identifiable {
    var npub: String
    var name: String
    var role: MeshDeviceRole

    var id: String { npub }

    /// The name, or the role when none was given.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.label : trimmed
    }
}

/// One stored My Devices entry, or nil when this build can't read it (a role
/// from a newer build). Lets the list decode entry by entry.
struct LossyMeshDevice: Decodable {
    let device: MeshDevice?

    init(from decoder: Decoder) throws {
        device = try? MeshDevice(from: decoder)
    }
}

/// Where a photo goes when it is posted. Stored only: the upload path reads
/// it (nv-3.0, Tom).
enum MeshPhotoDestination: String, CaseIterable, Identifiable {
    case publicServer = "public"
    case mac
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publicServer: return "Public server"
        case .mac: return "My Mac"
        case .both: return "Both"
        }
    }
}

/// The server that links two devices that can't reach each other directly.
enum MeshMiddleServer: String, CaseIterable, Identifiable {
    /// fips1 and fips2.iris.to: the route to anyone outside My Devices
    /// (follows' vaults read without a dial, a browser page, kiosk
    /// visitors). They see this phone's public IP while the mesh runs.
    case publicSeeds = "public"
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publicSeeds: return "Public (fips1, fips2.iris.to)"
        case .none: return "None"
        }
    }
}

enum MeshDevicesLogic {
    /// The finder relays every engine start used before they were editable.
    /// The engine's own defaults (damus, nos.lol, offchain.pub) carried no
    /// offers from Logen's network on 2026-10-21.
    static let defaultFinderRelays = [
        "wss://relay.nostr.net",
        "wss://nostr.bitcoiner.social",
        "wss://relay.btcforplebs.com",
    ]

    /// My Devices: the stored list, with the devices other settings point at
    /// (the Mac by its mesh address, the home vault, the browser page) kept in
    /// step. Each of those has one source of truth elsewhere, so a stored entry
    /// with that role whose source no longer names it is dropped, and a source
    /// with no stored entry yet gets one. Stored order is kept; new ones go last.
    static func merged(
        stored: [MeshDevice],
        macNpub: String?,
        homeVaultNpub: String?,
        browserNpub: String?
    ) -> [MeshDevice] {
        let sources: [(MeshDeviceRole, String?)] = [
            (.mac, macNpub), (.homeVault, homeVaultNpub), (.browser, browserNpub),
        ]
        func source(for role: MeshDeviceRole) -> String? {
            sources.first { $0.0 == role }?.1
        }
        var out: [MeshDevice] = []
        var seen = Set<String>()
        for device in stored where !seen.contains(device.npub) {
            if device.role != .phone, source(for: device.role) != device.npub { continue }
            seen.insert(device.npub)
            out.append(device)
        }
        for (role, npub) in sources {
            guard let npub, !seen.contains(npub) else { continue }
            seen.insert(npub)
            out.append(MeshDevice(npub: npub, name: "", role: role))
        }
        return out
    }

    /// The stored list with `device` in it: one entry per address, so adding
    /// an address again changes its name and role in place.
    static func adding(_ device: MeshDevice, to stored: [MeshDevice]) -> [MeshDevice] {
        var out = stored
        if let i = out.firstIndex(where: { $0.npub == device.npub }) {
            out[i] = device
        } else {
            // One Mac, one home vault and one browser page: a new one replaces
            // the old entry, as it replaces the setting behind it.
            if device.role != .phone { out.removeAll { $0.role == device.role } }
            out.append(device)
        }
        return out
    }

    /// Every role whose setting names `npub`. One address can be two of them
    /// (the Mac that is also the home vault), and the list shows it once, so
    /// Remove has to clear them all.
    static func rolesNaming(
        _ npub: String,
        macNpub: String?,
        homeVaultNpub: String?,
        browserNpub: String?
    ) -> [MeshDeviceRole] {
        let sources: [(MeshDeviceRole, String?)] = [
            (.mac, macNpub), (.homeVault, homeVaultNpub), (.browser, browserNpub),
        ]
        return sources.filter { $0.1 == npub }.map(\.0)
    }

    static func removing(npub: String, from stored: [MeshDevice]) -> [MeshDevice] {
        stored.filter { $0.npub != npub }
    }

    /// How many of `devices` the running engine is connected to.
    static func inReachCount(_ devices: [MeshDevice], peers: Set<String>) -> Int {
        devices.filter { peers.contains($0.npub) }.count
    }

    /// The one status line under the Mesh switch.
    static func statusLine(enabled: Bool, running: Bool, inReach: Int, total: Int) -> String {
        guard enabled else { return "Off" }
        guard running else { return "On · starts when needed" }
        guard total > 0 else { return "On · no devices yet" }
        return "On · \(inReach) of \(total) devices in reach"
    }

    /// Start options for the Mac's engine: only My Devices reach it (the
    /// engine's `own_devices`), each dialed at start. Nil with no devices,
    /// because an empty `own_devices` would open the Mac to anyone; the Mac
    /// then stays off. `ownNpub` (this Mac) is left out. `meshDoorPort` is
    /// Haven's mesh door (HavenConfig.meshPlainPort), where strangers go.
    static func macEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], meshDoorPort: Int) -> [String: Any]? {
        var npubs: [String] = []
        for device in devices where device.npub != ownNpub && !npubs.contains(device.npub) {
            npubs.append(device.npub)
        }
        guard !npubs.isEmpty else { return nil }
        // Strangers reach the Mac through the public seeds, capped
        // (fips-v2-android strangers.rs), and get only Haven's mesh door:
        // blob reads and owner-signed writes, never the relay port.
        guard (1...Int(UInt16.max)).contains(meshDoorPort) else { return nil }
        // `lan`: the Mac's answers carry its LAN address too, as the iPhone's
        // and the old helper's (`--lan`) do. A phone on the same Wi-Fi gets
        // only the shared public address without it, and most home routers
        // do not hairpin, so it never links. Only My Devices get answers.
        return [
            "own_devices": npubs,
            "relays": relays.isEmpty ? defaultFinderRelays : relays,
            "public_seeds": true,
            "strangers_port": meshDoorPort,
            "lan": true,
        ]
    }

    /// Start options for an iPhone sharing as a kiosk (home vault): the same
    /// own-devices engine as the Mac. Only My Devices get answers to their
    /// offers, so the home's addresses go to no one else, and are dialed at
    /// start; strangers reach the kiosk through the public seeds, capped,
    /// and get only Haven's mesh door, which serves blobs public notes name.
    /// `max_serve_bytes` is what strangers together may pull per sharing
    /// session (own devices are uncapped): a phone's data may be metered,
    /// and 1 MiB/s alone is 3.6 GB an hour (strangers.rs).
    /// Nil with no other device listed: an empty `own_devices` would leave
    /// the kiosk open to anyone, so it does not start.
    /// `seeds` false (middle server None): no seeds, so no visitors reach
    /// the kiosk and follows' vaults are out of reach; own devices still are.
    static func kioskEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], meshDoorPort: Int, seeds: Bool = true) -> [String: Any]? {
        guard var options = macEngineOptions(devices: devices, ownNpub: ownNpub, relays: relays, meshDoorPort: meshDoorPort) else { return nil }
        options["max_serve_bytes"] = kioskStrangersTotal
        options["public_seeds"] = seeds
        // Reading a follow's photos while sharing: without a dial, as a client does.
        options["read_anyone"] = true
        return options
    }

    /// Strangers' total per kiosk sharing session.
    static let kioskStrangersTotal: Int64 = 1 << 30

    /// Start options for an iPhone that reads: the Mac and the vaults of
    /// people you follow. Offers are answered for My Devices only (for no
    /// one with none listed), and a vault outside My Devices is read through
    /// the public seeds without a dial (`read_anyone`), so it never learns
    /// this phone's address. `seeds` is false when the middle server is set
    /// to None: those vaults are then out of reach and photos load from
    /// their URL, but the engine is still never open.
    static func clientEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], seeds: Bool) -> [String: Any] {
        var npubs: [String] = []
        for device in devices where device.npub != ownNpub && !npubs.contains(device.npub) {
            npubs.append(device.npub)
        }
        return [
            "own_devices": npubs,
            "read_anyone": true,
            "relays": relays.isEmpty ? defaultFinderRelays : relays,
            "public_seeds": seeds,
            // LAN candidates go only to My Devices: they alone get answers or dials.
            "lan": true,
        ]
    }

    /// A finder relay as typed: `wss://` added when missing, trailing
    /// slashes dropped. Nil for anything that is not a websocket host.
    static func normalizedFinderRelay(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("wss://") && !text.lowercased().hasPrefix("ws://") {
            guard !text.contains("://") else { return nil }
            text = "wss://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, !host.contains(" ") else { return nil }
        return text
    }
}

extension HavenConfig {
    /// Where a posted photo goes; an unknown stored value reads as the default.
    var photoDestination: MeshPhotoDestination {
        get { MeshPhotoDestination(rawValue: meshPhotoDestination) ?? .publicServer }
        set { meshPhotoDestination = newValue.rawValue }
    }
}
