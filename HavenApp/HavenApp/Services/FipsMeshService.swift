#if os(iOS)
import Foundation
import UIKit
import Security
import UserNotifications

/// The FIPS mesh on iPhone: libnvfips (nvfips.h), the same engine as Android.
///
/// iOS suspends background apps, so an iPhone only hosts in opt-in kiosk
/// mode: the app stays open on screen, the screen stays on, and the vault's
/// relay port (which also serves Blossom) is shared on the mesh. Leaving the
/// app ends kiosk mode. No background modes are used to keep it alive.
@MainActor
final class FipsMeshService: ObservableObject {
    static let shared = FipsMeshService()

    struct Status: Decodable {
        var running: Bool
        var npub: String?
        var exported: [Int]?
        var counters: Counters?
        /// The mesh pulled `max_serve_bytes` and the engine stopped sharing.
        var cap_reached: Bool?
        var max_serve_bytes: UInt64?
        /// The engine can hand notes to a browser relay page (relay_push).
        var relay_link: Bool?
        /// Npubs the engine is connected to now: My Devices' in-reach dots.
        var peers: [String]?
        /// This phone's mesh IP.
        var address: String?

        /// Bytes strangers pulled through the mesh door (own-devices mode).
        var strangers: Strangers?

        struct Strangers: Decodable {
            var tx: UInt64
        }

        struct Counters: Decodable {
            var served_open: UInt64
            var served_total: UInt64
            var served_tx: UInt64
        }
    }

    @Published private(set) var kioskActive = false
    /// A start is in flight. The toggle shows on, and a second tap cancels it.
    @Published private(set) var starting = false
    @Published private(set) var status: Status?
    @Published private(set) var lastError: String?
    /// Strangers used up today's serve limit; kiosk mode stays on, My Devices
    /// keep full access, and strangers are served again at this time
    /// (KioskCapPause, KioskDailyBudget).
    @Published private(set) var pausedUntil: Date?
    /// What strangers pulled today, across sessions and launches.
    private var budget = FipsMeshService.loadBudget()
    /// The day the running kiosk session started, and took its limit from.
    private var sessionDay = ""
    private static let budgetKey = "fipsMesh.kioskDailyBudget"

    private var pollTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    /// The last start or stop sent to the engine. Each new one waits for it,
    /// so a stop can never land after the start that follows it.
    private var engineOp: Task<Void, Never>?
    /// Bumped by each start and each cancel. Only the latest start can go live;
    /// an older one that finishes stops the engine instead.
    private var startGen = 0
    /// The engine is running only to reach other vaults (the home vault
    /// sender), not to share this one. Kiosk mode reuses it.
    private var clientActive = false
    private var clientBackgroundObserver: NSObjectProtocol?
    /// Client starts queued or dialing. clientActive is set only once a dial
    /// returns (~10 s, a relay push up to 90 s), and each start carries the
    /// My Devices it was queued with, so a revoke must count these too.
    private var clientOps = 0
    private init() {}

    /// Kiosk mode was on when the app last left the screen. Leaving the app
    /// stops it (iOS would suspend the mesh), and coming back starts it again.
    private static let kioskWantedKey = "fipsMesh.kioskWanted"
    private static let pausedNoteID = "fipsmesh-kiosk-paused"
    private var activeObserver: NSObjectProtocol?

    /// Called once at launch: turns kiosk mode back on each time the app comes
    /// on screen, if it was on when the app left.
    func resumeWhenActive() {
        guard activeObserver == nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeIfWanted() }
        }
    }

    private func resumeIfWanted() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.pausedNoteID])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.pausedNoteID])
        guard UserDefaults.standard.bool(forKey: Self.kioskWantedKey), !kioskActive, !starting else { return }
        print("FipsMesh: app back on screen, turning kiosk mode on again")
        startKiosk()
    }

    /// Kiosk mode stopped because the app left the screen: a tap on this
    /// opens the app, which turns it on again.
    private func notifyPaused() {
        let content = UNMutableNotificationContent()
        content.title = "Home vault mode paused"
        content.body = "Your vault stopped sharing on the mesh when Nostr Vault left the screen. Tap to share again."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: Self.pausedNoteID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("FipsMesh: kiosk paused notification failed: \(error)") }
        }
    }

    /// This phone's mesh npub, remembered from the last time the engine ran,
    /// so a 10063 published while it is off can drop this phone's old entry.
    var ownMeshNpub: String? { status?.npub ?? UserDefaults.standard.string(forKey: Self.ownNpubKey) }
    private static let ownNpubKey = "fipsMesh.ownNpub"

    /// The 10063 entry for this phone's vault while kiosk mode is on.
    var meshServerURL: String? {
        guard kioskActive, let npub = status?.npub else { return nil }
        return "fipsmesh://\(npub)/"
    }

    func startKiosk() {
        guard !kioskActive, !starting else { return }
        guard FipsMeshSettings.enabled else {
            lastError = Self.offMessage
            return
        }
        // Own devices get the relay in full, as on the Mac, but on its plain
        // loopback port: the iPhone relay port is TLS, and the mesh splices
        // plain HTTP (a sender hitting the TLS port got Go's 400 and dropped
        // the photo). Strangers get the relay's mesh door (blob reads and
        // owner-signed writes). They must differ: the engine refuses to share
        // the strangers' door as the relay port (share_split, -5).
        let port = ConfigService.shared.config.meshOwnPort
        let door = ConfigService.shared.config.meshPlainPort
        // Own-devices mode, as on the Mac: only My Devices get answers (the
        // home IP goes to no one else) and strangers get the mesh door,
        // capped. Never open: with no other device listed, sharing does not start.
        // Strangers get only what is left of today (KioskDailyBudget).
        budget.roll(to: Date())
        guard let options = MeshDevicesLogic.kioskEngineOptions(
            devices: FipsMeshDevices.current(ConfigService.shared.config), ownNpub: ownMeshNpub ?? Self.meshNpubFromKey(),
            relays: FipsMeshSettings.finderRelays, meshDoorPort: door,
            seeds: FipsMeshSettings.middleServer == .publicSeeds,
            serveBytes: budget.sessionLimit) else {
            lastError = "Add your other phone or your home vault under My Devices first: home vault mode serves your own devices in full, and anyone else only the photos you post."
            return
        }
        // Always a cold start. NvFipsStart keeps a running engine and drops
        // new options, and an open client engine can be up while clientActive
        // is still false (ingressURL sets it only once its dial returns), so
        // a check on clientActive would let kiosk mode inherit an open engine
        // and share the relay port with anyone (Tron, #1023). stopEngine
        // queues on engineOp, after any dial already in flight.
        clientActive = false
        if let clientBackgroundObserver { NotificationCenter.default.removeObserver(clientBackgroundObserver) }
        clientBackgroundObserver = nil
        stopEngine()
        starting = true
        startGen += 1
        let gen = startGen
        lastError = nil
        budget.engineStarted()
        sessionDay = budget.day
        saveBudget()
        let optionsJSON = Self.startOptions(options)
        let previous = engineOp
        engineOp = Task.detached(priority: .userInitiated) {
            await previous?.value
            let result = Self.startAndShare(port: port, options: optionsJSON)
            await MainActor.run { self.didStart(gen: gen, result) }
        }
    }

    /// `leavingApp`: the app left the screen, so kiosk mode comes back with it.
    /// Otherwise the owner turned it off. Kiosk mode never signs a 10063:
    /// only Save does (Logen, 2026-10-31).
    func stopKiosk(leavingApp: Bool = false) {
        if !leavingApp { UserDefaults.standard.set(false, forKey: Self.kioskWantedKey) }
        if starting {
            // didStart sees the cancel and stops the engine.
            starting = false
            startGen += 1
            return
        }
        guard kioskActive else { return }
        kioskActive = false
        pausedUntil = nil
        UIApplication.shared.isIdleTimerDisabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        stopEngine()
        status = nil
        if leavingApp { notifyPaused() }
    }

    /// My Devices changed. A running engine keeps the `own_devices` it started
    /// with, so a removed (lost or stolen) phone would keep reaching this
    /// vault: restart it with the new list (NIP-F1 revoke). `before` is the
    /// list from just before the change.
    func myDevicesChanged(from before: [MeshDevice]) {
        let after = FipsMeshDevices.current(ConfigService.shared.config)
        let own = ownMeshNpub ?? Self.meshNpubFromKey()
        // Any engine that may be up, not just clientActive: a dial still in
        // flight has an engine running, or queued, with the old list (Tron, #1054).
        // Not with kiosk mode up or starting: that branch wins anyway, and the
        // status call would wait on the engine's lock through a start (R2).
        let client = clientActive || clientOps > 0 || (!(kioskActive || starting) && Self.engineRunning())
        switch MeshDevicesLogic.engineAfterDevicesChange(before: before, after: after, ownNpub: own,
                                                         kiosk: kioskActive || starting, client: client) {
        case .keep:
            return
        case .restartKiosk:
            print("FipsMesh: My Devices changed, kiosk mode starts again with the new list")
            // No other device left: kiosk mode can't start, so it goes off.
            let startsAgain = !MeshDevicesLogic.ownDevices(after, ownNpub: own).isEmpty
            stopKiosk()
            if startsAgain {
                // Still wanted: if this start fails or the app leaves
                // mid-start, coming back tries again (resumeIfWanted).
                UserDefaults.standard.set(true, forKey: Self.kioskWantedKey)
                startKiosk()
            }
        case .stopClient:
            print("FipsMesh: My Devices changed, client engine stopped")
            clientActive = false
            if let clientBackgroundObserver { NotificationCenter.default.removeObserver(clientBackgroundObserver) }
            clientBackgroundObserver = nil
            // Queued after any dial in flight, so its start (with the old
            // list) can't outlive this stop.
            stopEngine()
            status = nil
        }
        // The relay dials a Mac set by its mesh address once, at start,
        // through this engine; a cold start drops that link: dial again.
        if ConfigService.shared.config.macRelayMeshNpub != nil {
            Task { _ = await RelayProcessManager.shared.gracefulRestart() }
        }
    }

    nonisolated private static func engineRunning() -> Bool {
        guard let raw = NvFipsStatusJSON() else { return false }
        defer { NvFipsFreeString(raw) }
        return (try? JSONDecoder().decode(Status.self, from: Data(String(cString: raw).utf8)))?.running == true
    }

    private func stopEngine() {
        let previous = engineOp
        engineOp = Task.detached {
            await previous?.value
            SetMeshServingC(0)
            NvFipsStop()
        }
    }

    private func didStart(gen: Int, _ result: Result<Void, MeshError>) {
        guard starting, gen == startGen else {
            // Cancelled while starting, or superseded by a newer start. A newer
            // start still in flight reuses this engine (start is idempotent), and a
            // stop queued here would land after it, so only stop when none is.
            if case .success = result, !starting { stopEngine() }
            return
        }
        starting = false
        switch result {
        case .failure(let error):
            lastError = error.message
        case .success:
            // The app left while the engine was starting: kiosk mode never goes live.
            guard UIApplication.shared.applicationState != .background else {
                stopEngine()
                return
            }
            kioskActive = true
            UserDefaults.standard.set(true, forKey: Self.kioskWantedKey)
            UIApplication.shared.isIdleTimerDisabled = true
            // print reaches relay.log (stdout), the file pulled off a device.
            print("FipsMesh: kiosk live, My Devices only, strangers at the mesh door (\(budget.remaining) bytes left today)")
            // Today's budget was used up before this start: strangers wait
            // for tomorrow from the first poll on.
            if budget.spent { pausedUntil = KioskDailyBudget.nextDay(after: Date()) }
            // Leaving the app ends kiosk mode: iOS would suspend the mesh anyway.
            // A banner or Control Center (willResignActive) does not.
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopKiosk(leavingApp: true) }
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }
    }

    // MARK: - Mesh on/off

    /// Kiosk mode, a start in flight and any client engine all stop.
    private func stopAll() {
        stopKiosk()
        if starting {
            starting = false
            startGen += 1
        }
        if clientActive {
            clientActive = false
            if let clientBackgroundObserver { NotificationCenter.default.removeObserver(clientBackgroundObserver) }
            clientBackgroundObserver = nil
        }
        stopEngine()
        status = nil
    }

    /// Reset Everything: the engine stops with the old key before
    /// `MeshIdentityReset` deletes it, so nothing keeps the old mesh npub.
    func stopForReset() {
        stopAll()
        lastError = nil
    }

    static let offMessage = "The mesh is off. Turn it on in Settings → Mesh."

    /// The Mesh switch. Off stops kiosk mode and any client engine, and every
    /// later start (kiosk, home vault, browser relay, the Mac) is refused
    /// until it is on again.
    func setEnabled(_ on: Bool) {
        guard on != FipsMeshSettings.enabled else { return }
        FipsMeshSettings.enabled = on
        lastError = nil
        if !on { stopAll() }
        // The relay dials a Mac set by its mesh address once, at start:
        // restart it so it drops that link, or makes it again.
        if ConfigService.shared.config.macRelayMeshNpub != nil {
            Task { _ = await RelayProcessManager.shared.gracefulRestart() }
        }
    }

    // MARK: - Client: reaching another vault

    /// A loopback base, `http://127.0.0.1:<port>/<token>`, whose requests reach
    /// `meshNpub`'s vault over the mesh; nil if the engine or the dial fails.
    /// Starts the engine as a client when nothing is running. A client never
    /// shares: the relay's mesh door stays shut unless kiosk mode opened it.
    /// Can take ~10 s (the node finds the vault through its advert).
    func ingressURL(meshNpub: String) async -> URL? {
        guard FipsMeshSettings.enabled else { return nil }
        let sharing = kioskActive || starting
        let clientOptions = clientOptionsJSON()
        let previous = engineOp
        let op = Task.detached(priority: .userInitiated) { () -> URL? in
            await previous?.value
            return Self.startClientAndIngress(meshNpub: meshNpub, closeDoor: !sharing, clientOptions: clientOptions)
        }
        engineOp = Task { _ = await op.value }
        clientOps += 1
        let url = await op.value
        clientOps -= 1
        if url != nil { refresh() }
        // The dial failed but the engine may be up: nothing else needs it.
        if url == nil, !kioskActive, !starting, !clientActive { stopEngine() }
        if url != nil { markClientActive() }
        return url
    }

    /// The local websocket address of the Haven relay at `meshNpub` (the
    /// owner's Mac given as a mesh npub), or nil if the dial fails. Never log
    /// it: the path holds the ingress token.
    func relayWebsocketURL(meshNpub: String) async -> String? {
        guard let base = await ingressURL(meshNpub: meshNpub) else { return nil }
        return HomeVaultLogic.websocketURL(base: base)?.absoluteString
    }

    /// The engine is up as a client (not kiosk mode): stop it once the app has
    /// been in the background a while.
    private func markClientActive() {
        guard !kioskActive, !starting, !clientActive else { return }
        clientActive = true
        // iOS suspends the engine in the background anyway; stop it cleanly
        // once the sender has had its background window.
        clientBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                MainActor.assumeIsolated { self?.stopClientIfBackground() }
            }
        }
    }

    // MARK: - Browser relay: handing notes to a nostrvault.app relay page

    /// libnvfips: the engine was started without the relay link.
    nonisolated private static let errRelayOff: Int32 = -7

    /// Start options for every engine start. Advert and signaling relays are
    /// the owner's finder relays (FIPS Mesh → Advanced; the defaults are
    /// MeshDevicesLogic.defaultFinderRelays). With a browser relay set up, the
    /// engine also opens its datagram API socket, so `relayPush` works
    /// whichever start came first, and joins the public seeds (the page's
    /// route) unless the middle server is set to None.
    nonisolated static func startOptions(_ base: [String: Any] = [:]) -> String {
        var options = base
        options["relays"] = FipsMeshSettings.finderRelays
        if BrowserRelaySender.isOn {
            if FipsMeshSettings.middleServer == .publicSeeds { options["public_seeds"] = true }
            options["relay_socket"] = relaySocketPath
        }
        guard let data = try? JSONSerialization.data(withJSONObject: options),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The client engine's start options, JSON: My Devices only, anyone
    /// else read without a dial.
    private func clientOptionsJSON() -> String {
        Self.startOptions(MeshDevicesLogic.clientEngineOptions(
            devices: FipsMeshDevices.current(ConfigService.shared.config),
            ownNpub: ownMeshNpub ?? Self.meshNpubFromKey(),
            relays: FipsMeshSettings.finderRelays,
            seeds: FipsMeshSettings.middleServer == .publicSeeds))
    }

    /// Inside the app's tmp dir: short enough for a socket path (libnvfips
    /// refuses one over 100 bytes; this is about 95).
    nonisolated private static var relaySocketPath: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("nvr.sock")
    }

    /// Starts the engine as a client with the relay link, if nothing runs yet,
    /// so the page can find this phone. Returns this phone's mesh npub.
    func connectForBrowserRelay() async -> String? {
        guard FipsMeshSettings.enabled else {
            lastError = Self.offMessage
            return nil
        }
        let sharing = kioskActive || starting
        let clientOptions = clientOptionsJSON()
        let previous = engineOp
        let op = Task.detached(priority: .userInitiated) { () -> Bool in
            await previous?.value
            return Self.startClientWithRelayLink(closeDoor: !sharing, clientOptions: clientOptions)
        }
        engineOp = Task { _ = await op.value }
        clientOps += 1
        let started = await op.value
        clientOps -= 1
        guard started else {
            lastError = "The mesh did not start"
            return nil
        }
        markClientActive()
        refresh()
        return status?.npub
    }

    /// Hand signed events to the browser relay page `relayNpub`. The result
    /// JSON from libnvfips, or an error in plain words. Can take up to
    /// `timeoutMs` while the page opens its session to this phone.
    func relayPush(relayNpub: String, eventsJSON: String, timeoutMs: UInt32 = 90_000) async -> Result<String, MeshError> {
        guard FipsMeshSettings.enabled else { return .failure(MeshError(message: Self.offMessage)) }
        let sharing = kioskActive || starting
        let clientOptions = clientOptionsJSON()
        let previous = engineOp
        let op = Task.detached(priority: .userInitiated) { () -> Result<String, MeshError> in
            await previous?.value
            guard Self.startClientWithRelayLink(closeDoor: !sharing, clientOptions: clientOptions) else {
                return .failure(MeshError(message: "The mesh did not start"))
            }
            var out: UnsafeMutablePointer<CChar>?
            let rc = NvFipsRelayPush(relayNpub, eventsJSON, timeoutMs, &out)
            guard rc == 0, let out else {
                if rc == Self.errRelayOff {
                    return .failure(MeshError(message: "Turn home vault mode off and on again to connect the browser vault"))
                }
                return .failure(MeshError(message: "Could not reach the browser vault (\(rc))"))
            }
            defer { NvFipsFreeString(out) }
            return .success(String(cString: out))
        }
        engineOp = Task { _ = await op.value }
        clientOps += 1
        let result = await op.value
        clientOps -= 1
        markClientActive()
        refresh()
        return result
    }

    /// Off the main thread. A running engine without the relay link is
    /// restarted with it, unless kiosk mode owns it.
    nonisolated private static func startClientWithRelayLink(closeDoor: Bool, clientOptions: String) -> Bool {
        guard let nsec = meshNsec() else { return false }
        // While sharing, the kiosk's engine is reused (start keeps a running one).
        guard NvFipsStart(nsec, clientOptions) == 0 else { return false }
        if closeDoor { SetMeshServingC(0) }
        if closeDoor, !engineHasRelayLink() {
            // Started earlier for the home vault, before a browser relay was set.
            NvFipsStop()
            guard NvFipsStart(nsec, clientOptions) == 0 else { return false }
            SetMeshServingC(0)
        }
        return true
    }

    nonisolated private static func engineHasRelayLink() -> Bool {
        guard let raw = NvFipsStatusJSON() else { return false }
        defer { NvFipsFreeString(raw) }
        let status = try? JSONDecoder().decode(Status.self, from: Data(String(cString: raw).utf8))
        return status?.relay_link == true
    }

    private func stopClientIfBackground() {
        guard clientActive, UIApplication.shared.applicationState == .background else { return }
        // The Mac's full-history copy runs over this engine: keep it up until
        // the copy ends, then give the usual 25 s.
        if macSyncNeedsMesh() {
            waitForMacSyncEnd()
            return
        }
        clientActive = false
        if let clientBackgroundObserver { NotificationCenter.default.removeObserver(clientBackgroundObserver) }
        clientBackgroundObserver = nil
        // Kiosk mode cannot be on in the background, so nothing else needs the engine.
        guard !kioskActive, !starting else { return }
        stopEngine()
        print("FipsMesh: client engine stopped in the background")
    }

    private func macSyncNeedsMesh() -> Bool {
        RelayConfiguration.macSyncNeedsMesh(
            mesh: RelayConfiguration.macMeshRelay,
            status: RelayConfiguration.macSyncStatus(under: ConfigService.shared.relayDataDir),
            now: Date()
        )
    }

    /// Checks every 5 s while the Mac copy runs; once it ends, the engine
    /// stops 25 s later if the app is still in the background.
    private func waitForMacSyncEnd() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.clientActive,
                      UIApplication.shared.applicationState == .background else { return }
                if self.macSyncNeedsMesh() {
                    self.waitForMacSyncEnd()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                        MainActor.assumeIsolated { self?.stopClientIfBackground() }
                    }
                }
            }
        }
    }

    nonisolated private static func startClientAndIngress(meshNpub: String, closeDoor: Bool, clientOptions: String) -> URL? {
        guard let nsec = meshNsec() else { return nil }
        // Idempotent: a running engine (kiosk or an earlier client start) is
        // reused. A client answers and dials only My Devices; anyone else's
        // vault is read through the seeds without learning this phone's
        // address (MeshDevicesLogic.clientEngineOptions).
        guard NvFipsStart(nsec, clientOptions) == 0 else { return nil }
        if closeDoor { SetMeshServingC(0) }
        var out: UnsafeMutablePointer<CChar>?
        let rc = NvFipsIngress(meshNpub, &out)
        guard rc == 0, let out else {
            print("FipsMesh: ingress to \(meshNpub.prefix(16)) failed (\(rc))")
            return nil
        }
        defer { NvFipsFreeString(out) }
        // Never log this: the path holds the token that keeps other apps out.
        return URL(string: String(cString: out))
    }

    func refresh() {
        guard let raw = NvFipsStatusJSON() else { return }
        defer { NvFipsFreeString(raw) }
        status = try? JSONDecoder().decode(Status.self, from: Data(String(cString: raw).utf8))
        if let npub = status?.npub { UserDefaults.standard.set(npub, forKey: Self.ownNpubKey) }
        guard kioskActive else { return }
        if let tx = status?.strangers?.tx {
            let before = budget
            budget.record(engineTx: tx, now: Date())
            if budget != before { saveBudget() }
        }
        // At the limit the engine stops serving strangers by itself. Kiosk
        // mode stays on and shares again when the budget allows: turning it
        // off would let anyone who uses up the limit keep the kiosk off until
        // the owner came back.
        let now = Date()
        switch KioskCapPause.step(capReached: status?.cap_reached == true, pausedUntil: pausedUntil, now: now, shareAgainAt: {
            let at = budget.capReached(sessionDay: sessionDay, now: now)
            saveBudget()
            return at
        }) {
        case .none:
            break
        case .pause(let until):
            print("FipsMesh: kiosk paused for strangers, today's serve limit reached, sharing again at \(until)")
            pausedUntil = until
        case .resume:
            shareAgain()
        }
    }

    /// Strangers may be served again: a new session, which takes its limit
    /// from the budget at start, so this is a fresh start rather than the
    /// engine's share-again (that would keep the old session's limit).
    private func shareAgain() {
        print("FipsMesh: kiosk starting a new session for strangers")
        stopKiosk()
        UserDefaults.standard.set(true, forKey: Self.kioskWantedKey)
        startKiosk()
    }

    private static func loadBudget() -> KioskDailyBudget {
        if let data = UserDefaults.standard.data(forKey: budgetKey),
           let saved = try? JSONDecoder().decode(KioskDailyBudget.self, from: data) {
            return saved
        }
        return KioskDailyBudget(day: KioskDailyBudget.dayKey(Date()))
    }

    private func saveBudget() {
        guard let data = try? JSONEncoder().encode(budget) else { return }
        UserDefaults.standard.set(data, forKey: Self.budgetKey)
    }

    struct MeshError: Error {
        let message: String
    }

    /// Off the main thread: start can take seconds (relays, UDP bind).
    /// `options`: the start options JSON (MeshDevicesLogic.kioskEngineOptions).
    nonisolated private static func startAndShare(port: Int, options: String) -> Result<Void, MeshError> {
        guard let nsec = meshNsec() else {
            return .failure(MeshError(message: "Could not create the mesh key"))
        }
        // Checked before start, so a bad port never leaves the engine running.
        guard let port = UInt16(exactly: port) else {
            return .failure(MeshError(message: "Relay port \(port) is out of range"))
        }
        let rc = NvFipsStart(nsec, options)
        guard rc == 0 else { return .failure(MeshError(message: "Mesh did not start (\(rc))")) }
        // The relay's mesh port listens only while sharing.
        SetMeshServingC(1)
        let shared = NvFipsExport(port)
        guard shared == 0 else {
            SetMeshServingC(0)
            NvFipsStop()
            return .failure(MeshError(message: "Could not share the relay (\(shared))"))
        }
        return .success(())
    }

    // MARK: - Mesh key

    /// This phone's mesh npub from its stored key, without starting the engine,
    /// so the owner can put it on the Mac's offer allowlist before the first
    /// dial. Creates the key if there is none yet, as a start would.
    nonisolated static func meshNpubFromKey() -> String? {
        guard let nsec = meshNsec(), let decoded = Bech32.decode(nsec), decoded.hrp == "nsec",
              decoded.data.count == 32,
              let pkCStr = GetPublicKeyC(UnsafeMutablePointer(mutating: (decoded.hexString as NSString).utf8String))
        else { return nil }
        let pk = String(cString: pkCStr)
        free(pkCStr)
        guard let pubData = Bech32.hexToData(pk) else { return nil }
        return Bech32.encode(hrp: "npub", data: pubData)
    }

    // The mesh npub is the address readers dial, so it must survive restarts.
    // It is its own key, not the owner's nsec, and never leaves this device.
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let nsec = String(data: data, encoding: .utf8) {
            return nsec
        }
        // Only a key that is not there gets replaced. A read that failed
        // (locked, say) must not mint a second key: now that new keys go to
        // the app's group, an add would no longer collide with the old one,
        // and the mesh npub readers dial would change.
        guard status == errSecItemNotFound, let raw = NvFipsGenerateNsec() else { return nil }
        let nsec = String(cString: raw)
        NvFipsFreeString(raw)
        var insert = keychainQuery
        insert[kSecValueData as String] = Data(nsec.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // The app's own group, not the default one the widget shares.
        var grouped = insert
        if let group = CredentialStore.privateGroup { grouped[kSecAttrAccessGroup as String] = group }
        var added = SecItemAdd(grouped as CFDictionary, nil)
        if added == errSecMissingEntitlement {
            // A build without the group entitled: the default group still
            // beats having no mesh key at all (CredentialStore.store does the same).
            added = SecItemAdd(insert as CFDictionary, nil)
        }
        // Without a stored key the npub would change on every start.
        guard added == errSecSuccess else { return nil }
        return nsec
    }
}
#endif
