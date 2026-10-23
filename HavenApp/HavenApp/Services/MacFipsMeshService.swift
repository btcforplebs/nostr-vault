#if os(macOS)
import Foundation
import Security

/// The FIPS mesh in the Mac app: libnvfips (nvfips.h), the engine iPhone and
/// Android run, in place of the separate fipsv2-probe helper.
///
/// My Devices reach all of it: the engine starts with them as `own_devices`,
/// so it answers their offers alone, dials each one, and gives them this
/// Mac's relay port uncapped, as the helper's `serve --peer … --forward
/// 127.0.0.1:<relay port>` did. Everyone else (`strangers`) comes in through
/// the public seeds, capped, to Haven's mesh door (meshPlainPort, open while
/// SetMeshServingC(1)), as the iPhone kiosk's visitors do: blob reads and
/// owner-signed writes only, never the relay port. With no devices it does
/// not start, since an empty list would be open to anyone. The vaults of
/// people you follow are read through the seeds with no dial (ingressURL).
@MainActor
final class MacFipsMeshService: ObservableObject {
    static let shared = MacFipsMeshService()

    struct Status: Decodable {
        var running: Bool
        var npub: String?
        var address: String?
    }

    @Published private(set) var status: Status?
    @Published private(set) var starting = false
    @Published private(set) var lastError: String?

    /// The options the running engine started with (devices, relays, port).
    /// My Devices is fixed at start, so a change restarts the engine.
    private var runningKey: String?
    /// The last start or stop sent to the engine; each new one waits for it.
    private var engineOp: Task<Void, Never>?
    /// Bumped by each sync; only the latest one reports back.
    private var syncGen = 0
    private var pollTimer: Timer?

    private init() {}

    /// The Mesh switch on the Mac. Off by default: the Mac starts sharing
    /// with its devices only when the owner turns it on.
    nonisolated private static let enabledKey = "fipsMesh.macEngine"
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: MacFipsMeshService.enabledKey)

    /// This Mac's mesh npub, from its stored key, so the page shows it (and
    /// refuses it as a device) before the first start: phones need it in
    /// My Devices before the Mac has anyone to start for.
    @Published private(set) var storedNpub: String? = UserDefaults.standard.string(forKey: MacFipsMeshService.ownNpubKey)
    var ownNpub: String? { status?.npub ?? storedNpub }
    nonisolated private static let ownNpubKey = "fipsMesh.macOwnNpub"

    var running: Bool { status?.running == true }

    /// Reads (or creates) the mesh key off the main thread, for the page.
    func loadOwnNpub() {
        guard storedNpub == nil else { return }
        Task {
            let npub = await Task.detached { Self.meshNpubFromKey() }.value
            guard let npub else { return }
            UserDefaults.standard.set(npub, forKey: Self.ownNpubKey)
            self.storedNpub = npub
            PhotoNode.ensureListed(owner: NostrService.shared.activeHexPubkey, nostr: .shared)
        }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        sync()
        // The photo node (PhotoNode) is listed while the switch is on.
        if on { NostrService.shared.publishServerList() }
    }

    /// This Mac's mesh npub while the switch is on: the photo node strangers
    /// read from. Any thread; nil before the key exists.
    nonisolated static func photoNpub() -> String? {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return nil }
        return UserDefaults.standard.string(forKey: ownNpubKey)
    }

    /// Brings the engine in line with the switch and My Devices: starts it,
    /// restarts it with a changed list, or stops it. Called at launch, from
    /// the switch, and after each My Devices change.
    func sync() {
        syncGen += 1
        let gen = syncGen
        lastError = nil
        let config = ConfigService.shared.config
        let options = enabled
            ? MeshDevicesLogic.macEngineOptions(devices: config.meshDevices, ownNpub: ownNpub, relays: [],
                                                meshDoorPort: config.meshPlainPort)
            : nil
        guard let options, let port = UInt16(exactly: config.relayPort),
              let data = try? JSONSerialization.data(withJSONObject: options, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else {
            if enabled {
                lastError = config.meshDevices.isEmpty
                    ? "Add a device under My Devices. Only your own devices can reach this Mac."
                    : "Could not start the mesh"
            }
            if runningKey != nil || running { stopEngine() }
            return
        }
        let key = "\(json)|\(port)"
        guard key != runningKey else { return }
        let restart = runningKey != nil || running
        runningKey = key
        starting = true
        let previous = engineOp
        let op = Task.detached(priority: .userInitiated) { () -> String? in
            await previous?.value
            if restart { Self.stopAndCloseDoor() }
            return Self.startAndShare(options: json, port: port)
        }
        engineOp = Task { _ = await op.value }
        Task { @MainActor in
            let error = await op.value
            guard gen == self.syncGen else { return }
            self.starting = false
            if let error {
                self.runningKey = nil
                self.lastError = error
            }
            self.refresh()
            self.startPolling()
        }
    }

    /// Reset Everything: the engine stops with the old key before
    /// `MeshIdentityReset` deletes it and the switch, so the page shows no npub.
    func stopForReset() {
        stopEngine()
        enabled = false
        storedNpub = nil
    }

    private func stopEngine() {
        runningKey = nil
        starting = false
        pollTimer?.invalidate()
        pollTimer = nil
        status = nil
        let previous = engineOp
        engineOp = Task.detached {
            await previous?.value
            Self.stopAndCloseDoor()
        }
    }

    /// Haven's mesh door closes with the engine, as on the iPhone.
    nonisolated private static func stopAndCloseDoor() {
        SetMeshServingC(0)
        NvFipsStop()
    }

    private func startPolling() {
        guard pollTimer == nil, running else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard let raw = NvFipsStatusJSON() else { return }
        defer { NvFipsFreeString(raw) }
        status = try? JSONDecoder().decode(Status.self, from: Data(String(cString: raw).utf8))
        if let npub = status?.npub, npub != storedNpub {
            UserDefaults.standard.set(npub, forKey: Self.ownNpubKey)
            storedNpub = npub
        }
        // The photo node goes in the owner's 10063 as soon as its npub is known
        // (a first start learns it only here); a no-op once it is listed.
        if running { PhotoNode.ensureListed(owner: NostrService.shared.activeHexPubkey, nostr: .shared) }
    }

    /// Off the main thread: start can take seconds (relays, UDP bind).
    /// Nil on success, or the error in plain words.
    nonisolated private static func startAndShare(options: String, port: UInt16) -> String? {
        guard let nsec = meshNsec() else { return "Could not create the mesh key" }
        // FIPS's per-peer connected UDP socket stops rx on this Mac about a
        // second after the handshake (seen 2026-10-13), so the
        // link to a phone drops and redials. The helper ran with this off.
        setenv("FIPS_MACOS_CONNECTED_UDP", "0", 1)
        let rc = NvFipsStart(nsec, options)
        guard rc == 0 else { return "Mesh did not start (\(rc))" }
        // Strangers' door: Haven's mesh port listens only while sharing.
        SetMeshServingC(1)
        let shared = NvFipsExport(port)
        guard shared == 0 else {
            stopAndCloseDoor()
            return "Could not share the relay (\(shared))"
        }
        print("FipsMesh: Mac engine live, own devices on relay port \(port), capped strangers on the mesh door")
        return nil
    }

    // MARK: - Reading another vault

    /// A loopback base, `http://127.0.0.1:<port>/<token>`, whose requests reach
    /// `meshNpub`'s vault over the mesh, or nil (the photo then loads from its
    /// URL). Only while the Mesh switch has the engine up: reading never
    /// starts it. A vault outside My Devices is reached through the seeds with
    /// no dial (`read_anyone`). Can take ~10 s. Never log it: the path holds
    /// the ingress token.
    func ingressURL(meshNpub: String) async -> URL? {
        guard enabled, runningKey != nil else { return nil }
        // After a start or restart in flight, not queued behind other reads.
        let previous = engineOp
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            await previous?.value
            var out: UnsafeMutablePointer<CChar>?
            let rc = NvFipsIngress(meshNpub, &out)
            guard rc == 0, let out else {
                print("FipsMesh: ingress to \(meshNpub.prefix(16)) failed (\(rc))")
                return nil
            }
            defer { NvFipsFreeString(out) }
            return URL(string: String(cString: out))
        }.value
    }

    // MARK: - Mesh key

    /// This Mac's mesh npub from its stored key, without starting the engine.
    /// Creates the key if there is none yet, as a start would.
    nonisolated private static func meshNpubFromKey() -> String? {
        guard let nsec = meshNsec(), let decoded = Bech32.decode(nsec), decoded.hrp == "nsec",
              decoded.data.count == 32,
              let pkCStr = GetPublicKeyC(UnsafeMutablePointer(mutating: (decoded.hexString as NSString).utf8String))
        else { return nil }
        let pk = String(cString: pkCStr)
        free(pkCStr)
        guard let pubData = Bech32.hexToData(pk) else { return nil }
        return Bech32.encode(hrp: "npub", data: pubData)
    }

    // The mesh npub is the address the phones dial, so it must survive
    // restarts. It is its own key, not the owner's nsec, and never leaves this Mac.
    nonisolated private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: MeshIdentityReset.keychainService,
        kSecAttrAccount as String: "mesh-nsec",
    ]

    nonisolated private static func meshNsec() -> String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let nsec = String(data: data, encoding: .utf8) {
            return nsec
        }
        guard let raw = NvFipsGenerateNsec() else { return nil }
        let nsec = String(cString: raw)
        NvFipsFreeString(raw)
        var insert = keychainQuery
        insert[kSecValueData as String] = Data(nsec.utf8)
        // Without a stored key the npub would change on every start.
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return nil }
        return nsec
    }
}
#endif
