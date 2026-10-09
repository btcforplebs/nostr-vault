#if os(iOS)
import Foundation
import UIKit
import Security

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

    private var pollTimer: Timer?
    private var resignObserver: NSObjectProtocol?
    /// The last start or stop sent to the engine. Each new one waits for it,
    /// so a stop can never land after the start that follows it.
    private var engineOp: Task<Void, Never>?
    /// Bumped by each start and each cancel. Only the latest start can go live;
    /// an older one that finishes stops the engine instead.
    private var startGen = 0

    private init() {}

    /// The 10063 entry for this phone's vault while kiosk mode is on.
    var meshServerURL: String? {
        guard kioskActive, let npub = status?.npub else { return nil }
        return "fipsmesh://\(npub)/"
    }

    func startKiosk() {
        guard !kioskActive, !starting else { return }
        starting = true
        startGen += 1
        let gen = startGen
        lastError = nil
        // The relay's mesh port: plain HTTP, blob reads only.
        let port = ConfigService.shared.config.meshPlainPort
        let previous = engineOp
        engineOp = Task.detached(priority: .userInitiated) {
            await previous?.value
            let result = Self.startAndShare(port: port)
            await MainActor.run { self.didStart(gen: gen, result) }
        }
    }

    func stopKiosk() {
        if starting {
            // didStart sees the cancel and stops the engine.
            starting = false
            startGen += 1
            return
        }
        guard kioskActive else { return }
        kioskActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        stopEngine()
        status = nil
        publishServerListInBackgroundTask()
    }

    private func stopEngine() {
        let previous = engineOp
        engineOp = Task.detached {
            await previous?.value
            SetMeshServingC(0)
            NvFipsStop()
        }
    }

    /// stopKiosk runs from didEnterBackground: ask iOS for time so the 10063
    /// without the mesh entry goes out before the app is suspended.
    private func publishServerListInBackgroundTask() {
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "fipsmesh-10063") { end() }
        NostrService.shared.publishServerList()
        // publishServerList does not report completion; signing and posting take well under this.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { end() }
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
            UIApplication.shared.isIdleTimerDisabled = true
            // Leaving the app ends kiosk mode: iOS would suspend the mesh anyway.
            // A banner or Control Center (willResignActive) does not.
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopKiosk() }
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
            NostrService.shared.publishServerList()
        }
    }

    func refresh() {
        guard let raw = NvFipsStatusJSON() else { return }
        defer { NvFipsFreeString(raw) }
        status = try? JSONDecoder().decode(Status.self, from: Data(String(cString: raw).utf8))
    }

    struct MeshError: Error {
        let message: String
    }

    /// Off the main thread: start can take seconds (relays, UDP bind).
    nonisolated private static func startAndShare(port: Int) -> Result<Void, MeshError> {
        guard let nsec = meshNsec() else {
            return .failure(MeshError(message: "Could not create the mesh key"))
        }
        // Checked before start, so a bad port never leaves the engine running.
        guard let port = UInt16(exactly: port) else {
            return .failure(MeshError(message: "Relay port \(port) is out of range"))
        }
        // No start-time peers: anyone can reach this vault, and reading
        // another vault adds its npub on demand.
        let rc = NvFipsStart(nsec, "{}")
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

    // The mesh npub is the address readers dial, so it must survive restarts.
    // It is its own key, not the owner's nsec, and never leaves this device.
    nonisolated private static let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "to.nostrvault.fipsmesh",
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
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Without a stored key the npub would change on every start.
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { return nil }
        return nsec
    }
}
#endif
