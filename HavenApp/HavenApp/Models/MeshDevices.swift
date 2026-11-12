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
        case .mac: return "Desktop vault · full history"
        case .phone: return "Phone"
        case .homeVault: return "Mobile vault · new posts"
        case .browser: return "Browser vault"
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
        case .mac: return "Keeps all your history. Syncs both ways."
        case .phone: return "Another phone of yours on the mesh."
        case .homeVault: return "Keeps your new posts and media, and sends your notes on."
        case .browser: return "Gets your new notes while this app is open."
        }
    }
}

/// One entry in My Devices: a mesh address, a name and a role.
struct MeshDevice: Codable, Hashable, Identifiable {
    var npub: String
    var name: String
    var role: MeshDeviceRole
    /// A Mac's or box's own web domain (`host`, no scheme), when it has one.
    /// Tells this device which https entry in the owner's lists is one of
    /// theirs, so it can tell which device is public on the web (multi-Mac
    /// rules §3.3). nil for phones and for entries saved before it.
    var domain: String? = nil

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

/// Where new photos go, in the words Mesh settings show on iPhone and Mac
/// and the website's home vault help page. There is no choice to make: the
/// "Photos go to" picker set a value nothing read (Logen 2026-11-05).
enum MeshPhotoPath {
    static let explainer = "New photos are saved on this device first. If you have a mobile vault, a copy goes to it over the mesh, and the mobile vault puts it on your public media server for you. If this device has its own media server, it uploads there itself."
}

/// Kept so an older config still decodes; nothing reads or shows it any more
/// (the picker is gone, `MeshPhotoPath`).
enum MeshPhotoDestination: String, CaseIterable, Identifiable {
    case publicServer = "public"
    case mac
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publicServer: return "Media servers"
        case .mac: return "Desktop vault"
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
    /// step. The home vault and the browser page each have one source of truth
    /// elsewhere, so a stored entry with that role whose source no longer names
    /// it is dropped. Macs are not: any number of Macs and boxes are your
    /// devices (multi-Mac rules §4), and the Mac setting names only the first,
    /// for older callers. A source with no stored entry yet gets one. Stored
    /// order is kept; new ones go last.
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
            if device.role != .phone, device.role != .mac, source(for: device.role) != device.npub { continue }
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
            // One home vault and one browser page: a new one replaces the old
            // entry, as it replaces the setting behind it. An old home vault
            // stays one of your devices, as a plain device: switching vaults
            // must not drop it from My Devices, its mesh access or the 10063
            // (2026-10-22: Mac to Moto dropped the Mac). Macs and phones add:
            // another Mac is another full copy (multi-Mac rules §4).
            if device.role == .homeVault {
                for i in out.indices where out[i].role == .homeVault { out[i].role = .phone }
            } else if device.role == .browser {
                out.removeAll { $0.role == .browser }
            }
            out.append(device)
        }
        return out
    }

    /// Every Mac and box in My Devices, the Mac setting's one first (older
    /// callers know only that one), then My Devices order, each once, never
    /// this device. A Mac set only in the setting counts too.
    static func macs(_ devices: [MeshDevice], macNpub: String?, ownNpub: String?) -> [String] {
        var out: [String] = []
        if let macNpub, macNpub != ownNpub { out.append(macNpub) }
        for device in devices where device.role == .mac && device.npub != ownNpub && !out.contains(device.npub) {
            out.append(device.npub)
        }
        return out
    }

    /// What the Mac setting names after `removed` leaves My Devices: the next
    /// Mac, so the Mac sync and older callers keep a Mac while one is left;
    /// nil when none is. Removing a Mac the setting doesn't name changes
    /// nothing (`.some(macNpub)`).
    static func macSettingAfterRemoving(_ removed: String, devices: [MeshDevice], macNpub: String?) -> String? {
        guard macNpub == removed else { return macNpub }
        return devices.first { $0.role == .mac && $0.npub != removed }?.npub
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

    /// The Mac's status line under the Mesh switch: the iPhone's words, with
    /// the Mac's own states. The Mac starts its engine at once (no "when
    /// needed") and never with an empty list.
    static func macStatusLine(enabled: Bool, running: Bool, starting: Bool, inReach: Int, total: Int) -> String {
        guard enabled else { return "Off" }
        guard total > 0 else { return "On · no devices yet" }
        guard running else { return starting ? "Starting…" : "On · not running" }
        return statusLine(enabled: true, running: true, inReach: inReach, total: total)
    }

    /// Start options for the Mac's engine: only My Devices reach it (the
    /// engine's `own_devices`), each dialed at start. Nil with no devices,
    /// because an empty `own_devices` would open the Mac to anyone; the Mac
    /// then stays off. `ownNpub` (this Mac) is left out. `meshDoorPort` is
    /// Haven's mesh door (HavenConfig.meshPlainPort), where strangers go.
    /// A follow's vault outside My Devices is read through the seeds without
    /// a dial (`read_anyone`), so it never learns this Mac's address.
    static func macEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], meshDoorPort: Int) -> [String: Any]? {
        let npubs = ownDevices(devices, ownNpub: ownNpub)
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
            "read_anyone": true,
            "lan": true,
        ]
    }

    /// Start options for an iPhone sharing as a kiosk (home vault): the same
    /// own-devices engine as the Mac. Only My Devices get answers to their
    /// offers, so the home's addresses go to no one else, and are dialed at
    /// start; strangers reach the kiosk through the public seeds, capped,
    /// and get only Haven's mesh door, which serves blobs public notes name.
    /// `max_serve_bytes` is what strangers together may pull this sharing
    /// session (own devices are uncapped): a phone's data may be metered,
    /// and 1 MiB/s alone is 3.6 GB an hour (strangers.rs). The kiosk passes
    /// what is left of today's `KioskDailyBudget`.
    /// Nil with no other device listed: an empty `own_devices` would leave
    /// the kiosk open to anyone, so it does not start.
    /// `seeds` false (middle server None): no seeds, so no visitors reach
    /// the kiosk and follows' vaults are out of reach; own devices still are.
    static func kioskEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], meshDoorPort: Int, seeds: Bool = true, serveBytes: Int64 = kioskStrangersTotal) -> [String: Any]? {
        guard var options = macEngineOptions(devices: devices, ownNpub: ownNpub, relays: relays, meshDoorPort: meshDoorPort) else { return nil }
        options["max_serve_bytes"] = max(1, serveBytes)
        options["public_seeds"] = seeds
        return options
    }

    /// Strangers' total per day, all kiosk sharing sessions together.
    static let kioskStrangersTotal: Int64 = 1 << 30

    /// Start options for an iPhone that reads: the Mac and the vaults of
    /// people you follow. Offers are answered for My Devices only (for no
    /// one with none listed), and a vault outside My Devices is read through
    /// the public seeds without a dial (`read_anyone`), so it never learns
    /// this phone's address. `seeds` is false when the middle server is set
    /// to None: those vaults are then out of reach and photos load from
    /// their URL, but the engine is still never open.
    static func clientEngineOptions(devices: [MeshDevice], ownNpub: String?, relays: [String], seeds: Bool) -> [String: Any] {
        return [
            "own_devices": ownDevices(devices, ownNpub: ownNpub),
            "read_anyone": true,
            "relays": relays.isEmpty ? defaultFinderRelays : relays,
            "public_seeds": seeds,
            // LAN candidates go only to My Devices: they alone get answers or dials.
            "lan": true,
        ]
    }

    /// The engine's `own_devices`: My Devices without this device, each once.
    static func ownDevices(_ devices: [MeshDevice], ownNpub: String?) -> [String] {
        var npubs: [String] = []
        for device in devices where device.npub != ownNpub && !npubs.contains(device.npub) {
            npubs.append(device.npub)
        }
        return npubs
    }

    enum EngineAfterDevicesChange: Equatable {
        case keep
        /// Kiosk mode starts again with the new list: a removed device's
        /// open session drops, and its next offer gets no answer.
        case restartKiosk
        /// The client engine stops; the next dial starts it with the new list.
        case stopClient
    }

    /// What a running engine does after My Devices changes (NIP-F1: a lost
    /// phone's mesh npub must stop reaching the owner's other vaults). The
    /// engine's `own_devices` is fixed at start, so a changed list means a
    /// restart, as on the Mac (MacFipsMeshService.sync) and Android.
    static func engineAfterDevicesChange(before: [MeshDevice], after: [MeshDevice], ownNpub: String?,
                                         kiosk: Bool, client: Bool) -> EngineAfterDevicesChange {
        guard ownDevices(before, ownNpub: ownNpub) != ownDevices(after, ownNpub: ownNpub) else { return .keep }
        if kiosk { return .restartKiosk }
        if client { return .stopClient }
        return .keep
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
