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
    @Published private(set) var status: Status?
    @Published private(set) var lastError: String?

    private var pollTimer: Timer?
    private var resignObserver: NSObjectProtocol?

    private init() {}

    /// The 10063 entry for this phone's vault while kiosk mode is on.
    var meshServerURL: String? {
        guard kioskActive, let npub = status?.npub else { return nil }
        return "fipsmesh://\(npub)/"
    }

    func startKiosk() {
        guard !kioskActive else { return }
        lastError = nil
        let port = ConfigService.shared.config.relayPort
        Task.detached(priority: .userInitiated) {
            let result = Self.startAndShare(port: port)
            await MainActor.run { self.didStart(result) }
        }
    }

    func stopKiosk() {
        guard kioskActive else { return }
        kioskActive = false
        UIApplication.shared.isIdleTimerDisabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        Task.detached { NvFipsStop() }
        status = nil
        NostrService.shared.publishServerList()
    }

    private func didStart(_ result: Result<Void, MeshError>) {
        switch result {
        case .failure(let error):
            lastError = error.message
        case .success:
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
        // No start-time peers: anyone can reach this vault, and reading
        // another vault adds its npub on demand.
        let rc = NvFipsStart(nsec, "{}")
        guard rc == 0 else { return .failure(MeshError(message: "Mesh did not start (\(rc))")) }
        guard let port = UInt16(exactly: port) else {
            return .failure(MeshError(message: "Relay port \(port) is out of range"))
        }
        let shared = NvFipsExport(port)
        guard shared == 0 else {
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
