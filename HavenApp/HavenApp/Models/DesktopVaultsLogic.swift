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
        guard old != new else {
            // The slot's address held by no Vault (the stored list was lost
            // or dropped it): take it in again as new, so the owner's Mac
            // stays a Vault and out of "Delete from mirrors" (Tron M1, #2500).
            if !holds(vaults, new, ownNpub: ownNpub) {
                var out = ordered(vaults)
                addSlot(&out, new, slot: slot, devices: devices, ownNpub: ownNpub)
                return renumbered(out)
            }
            // Same host, new path or spelling (`/haven` to `/relay`): the
            // Vault takes the new address, as MAC_RELAY_URL does.
            guard case .web(let host) = new, httpsURL(taken) != httpsURL(slot),
                  let i = vaults.firstIndex(where: { $0.hostKey == host }) else { return vaults }
            var out = vaults
            out[i].httpsURL = httpsURL(slot)
            return out
        }
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
        if !holds(out, new, ownNpub: ownNpub) {
            addSlot(&out, new, slot: slot, devices: devices, ownNpub: ownNpub)
        }
        return renumbered(out)
    }

    /// Whether a Vault already has the slot's address (nothing to hold for an
    /// empty slot or this device's own npub).
    private static func holds(_ vaults: [DesktopVault], _ address: SlotAddress, ownNpub: String?) -> Bool {
        switch address {
        case .web(let host): return vaults.contains { $0.hostKey == host }
        case .mesh(let npub): return npub == ownNpub || vaults.contains { $0.meshNpub == npub }
        case .none: return true
        }
    }

    /// The slot's address goes to the `.mac` device whose domain it is, else
    /// to a new Vault, first.
    private static func addSlot(_ out: inout [DesktopVault], _ address: SlotAddress, slot: String,
                                devices: [MeshDevice], ownNpub: String?) {
        if case .web(let host) = address,
           let device = macDevice(domain: host, devices: devices, ownNpub: ownNpub),
           let i = out.firstIndex(where: { $0.meshNpub == device.npub }) {
            out[i].httpsURL = httpsURL(slot)
        } else {
            out.insert(vaultForSlot(address, typed: slot, devices: devices, ownNpub: ownNpub), at: 0)
        }
    }

    private static func renumbered(_ vaults: [DesktopVault]) -> [DesktopVault] {
        vaults.enumerated().map { i, vault in
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

    /// The list kept in step with My Devices after migration (Tron N1, N2 on
    /// #2499), since routing reads it (P3):
    /// - this device's own npub is never a Vault's mesh address (§2.6);
    /// - a Vault's mesh address goes when its `.mac` device leaves My
    ///   Devices, unless the slot still names it; a Vault left with no
    ///   address goes;
    /// - a `.mac` device with no Vault becomes one, on the HTTPS Vault whose
    ///   host is its domain, else as a new FIPS-only Vault at the end.
    /// Clearing the old tab takes only the slot's address off (N3): a Mac
    /// still in My Devices stays a Vault, as it already gets mesh lanes;
    /// removing it from My Devices is what turns it off.
    static func followingDevices(_ vaults: [DesktopVault], devices: [MeshDevice], slot: String,
                                 ownNpub: String?) -> [DesktopVault] {
        let holdable = holdableMeshNpubs(devices: devices, slot: slot, ownNpub: ownNpub)
        var out = ordered(vaults)
        for i in out.indices {
            guard let npub = out[i].meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) else { continue }
            if !holdable.contains(npub) { out[i].meshNpub = nil }
        }
        out.removeAll { $0.meshNpub == nil && $0.httpsURL == nil }
        for npub in MeshDevicesLogic.macs(devices, macNpub: nil, ownNpub: ownNpub)
            where !out.contains(where: { $0.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) == npub }) {
            let device = devices.first { $0.npub == npub }
            if let host = device?.domain.flatMap(DesktopVaultsLists.hostKey),
               let i = out.firstIndex(where: { $0.hostKey == host && $0.meshNpub == nil }) {
                out[i].meshNpub = npub
                if out[i].name.isEmpty { out[i].name = device?.name ?? "" }
            } else {
                out.append(DesktopVault(id: id(meshNpub: npub), name: device?.name ?? "", meshNpub: npub, order: out.count))
            }
        }
        return renumbered(out)
    }

    /// The mesh addresses `followingDevices` lets a Vault keep: a `.mac` in
    /// My Devices, or the slot's npub, never this device's own. The settings
    /// copy reads the same set to tell an address this device dropped (can't
    /// hold, so carried as the file has it) from one it deleted (#2521).
    static func holdableMeshNpubs(devices: [MeshDevice], slot: String, ownNpub: String?) -> Set<String> {
        var out = Set(devices.filter { $0.role == .mac }.map(\.npub))
        if case .mesh(let npub) = SlotAddress(slot) { out.insert(npub) }
        if let ownNpub { out.remove(ownNpub) }
        return out
    }

    /// The mesh npubs of the Vaults reachable over FIPS, in list order. The
    /// relay dials them in this order and publish-for-me takes the first
    /// that answers (§2.2 rule 3).
    static func meshNpubs(_ vaults: [DesktopVault]) -> [String] {
        var seen = Set<String>()
        return ordered(vaults).compactMap { vault in
            guard let npub = vault.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)),
                  seen.insert(npub).inserted else { return nil }
            return npub
        }
    }

    /// When the relay dials the mesh Vaults (Tron M1 on #2506). Only with
    /// FIPS on. Before the start only when the slot itself is a mesh npub:
    /// that Vault has no other way in, as before P3. Any other mesh Vault is
    /// dialed after the relay is up over wss, so a paired Mac out of reach
    /// never holds the launch start or a restart.
    enum MeshDial: Equatable {
        case none
        case beforeStart
        case afterStart
    }

    static func meshDial(fipsOn: Bool, slot: String, meshNpubs: [String]) -> MeshDial {
        guard fipsOn, !meshNpubs.isEmpty else { return .none }
        if case .mesh = SlotAddress(slot) { return .beforeStart }
        return .afterStart
    }

    /// What a start in `.afterStart` mode uses, by npub. The background
    /// dial's hand-over comes first. Otherwise, the mesh Vault the relay
    /// already held is dialed again on its own, not dropped (Tron M2 on
    /// #2513). A settings restart then stays on the mesh, instead of
    /// starting on wss and needing a second restart once the dial after the
    /// start finds it again. Either one only while it is still on the list.
    enum AfterStartPick: Equatable {
        case take(String)
        case redial(String)
        case none
    }

    static func afterStartPick(handedOver: String?, held: String?, meshNpubs: [String]) -> AfterStartPick {
        if let handedOver, meshNpubs.contains(handedOver) { return .take(handedOver) }
        if let held, meshNpubs.contains(held) { return .redial(held) }
        return .none
    }

    /// One total wait for all the dials of a start (Tron M1): one failed
    /// dial takes about this long, so N unreachable Macs no longer cost N×.
    static let meshDialBudget: TimeInterval = 10

    /// The first of `npubs`, in order, whose `dial` answers inside one
    /// shared `budget`. A dial still running when the budget ends is left
    /// to finish on its own (the FFI dial can't be interrupted) and its
    /// answer is dropped.
    static func firstAnswering(_ npubs: [String], budget: TimeInterval,
                               dial: @escaping @Sendable (String) async -> String?) async -> (npub: String, url: String)? {
        let deadline = Date().addingTimeInterval(budget)
        for npub in npubs {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            let url: String? = await withCheckedContinuation { continuation in
                let once = ResumeOnce(continuation)
                Task { once.resume(await dial(npub)) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
                    once.resume(nil)
                }
            }
            if let url { return (npub, url) }
        }
        return nil
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func resume(_ value: String?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Every HTTPS Vault's DM inbox, `wss://<base>/inbox`, in list order
    /// (§2.2 rule 2): where other people send DMs and the own sent copies go.
    /// Left out: a home-network address, which others can't reach, and the
    /// slot when it was typed as plain `ws://` or `http://`.
    static func dmInboxURLs(_ vaults: [DesktopVault], slot: String) -> [String] {
        let typed = slot.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plainHost: String? = typed.hasPrefix("ws://") || typed.hasPrefix("http://")
            ? DesktopVaultsLists.hostKey(typed) : nil
        return bases(vaults).compactMap { host, base in
            guard host != plainHost, !HavenConfig.isPrivateNetworkHost(base) else { return nil }
            return "wss://\(base)/inbox"
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
    ///
    /// A Vault MAC_RELAY_URL reaches over the mesh keeps its web address
    /// here (Tron M2 on #2506): the mesh link ends when the client engine
    /// stops in the background and nothing dials again until the next start,
    /// so its wss is the fallback (§2.2: mesh first, wss as fallback).
    /// `typed`: the old tab's value; a slot typed as plain `ws://`/`http://`
    /// that lands here keeps `ws://`, as MAC_RELAY_URL kept it.
    static func envList(_ vaults: [DesktopVault], slot: String, typed: String = "") -> String {
        let slotHost: String? = { if case .web(let host) = SlotAddress(slot) { return host } else { return nil } }()
        let lower = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plainHost = lower.hasPrefix("ws://") || lower.hasPrefix("http://") ? DesktopVaultsLists.hostKey(lower) : nil
        return bases(vaults).filter { $0.host != slotHost }
            .map { ($0.host == plainHost ? "ws://" : "wss://") + $0.base }.joined(separator: ",")
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
