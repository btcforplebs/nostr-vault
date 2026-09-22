#if os(macOS)
import Foundation
import Combine
import os

/// Mac side of the FIPS mesh bridge.
///
/// The Rust bridge is the same C ABI Android binds to (`fips_bridge.h`), so
/// this file is the Swift twin of `FipsMeshManager.kt` and deliberately mirrors
/// its shape: start under a persisted identity, export the local relay port,
/// poll a JSON status snapshot.
///
/// Control plane only. The bytes never cross this boundary — the bridge opens
/// its own loopback sockets, which is what lets every HTTP client in the
/// process reach a peer's Blossom with no interception anywhere.
@MainActor
final class FipsMeshService: ObservableObject {

    static let shared = FipsMeshService()

    struct Peer: Identifiable, Equatable {
        let npub: String
        /// Set when the peer is one of the known transit seeds.
        let alias: String?
        let connected: Bool
        let address: String?
        let rttMs: Int?

        var id: String { npub }
    }

    struct Status: Equatable {
        var running: Bool = false
        var npub: String = ""
        /// The endpoint's own mesh IPv6 address.
        var address: String = ""
        var uptimeSeconds: Int = 0
        /// Local TCP ports currently offered to the mesh.
        var exportedPorts: [Int] = []
        var peers: [Peer] = []

        static let stopped = Status()
    }

    /// Persisted in UserDefaults rather than HavenConfig: HavenConfig is
    /// Codable with a synthesised decoder, where a new non-Optional field makes
    /// every previously written config fail to decode.
    private static let enabledKey = "fipsMeshEnabled"

    @Published private(set) var status: Status = .stopped
    @Published private(set) var lastError: String?

    /// Whether the user has asked for the mesh. Off by default, and the only
    /// thing that starts the bridge — nothing here runs unless this is true.
    @Published private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: FipsMeshService.enabledKey)

    private var pollTimer: Timer?

    // The mesh address is the one fact a peer needs and the one fact the app
    // cannot derive from anything else on screen, so it goes to the unified log
    // as well as the UI — a headless check has nothing else to read.
    private let log = Logger(subsystem: "com.havenapp.relay", category: "fips-mesh")

    private init() {}

    // MARK: - Lifecycle

    /// Called once at launch, after the relay is up. Starts the bridge only if
    /// the user turned it on in a previous session.
    func restoreIfEnabled(relayPort: Int) {
        guard isEnabled else { return }
        start(relayPort: relayPort)
    }

    func setEnabled(_ enabled: Bool, relayPort: Int) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start(relayPort: relayPort)
        } else {
            stop()
        }
    }

    // MARK: - Bridge

    private func start(relayPort: Int) {
        lastError = nil

        let nsec = meshNsec()
        guard !nsec.isEmpty else {
            lastError = "Could not create a mesh identity."
            return
        }

        let rc = nsec.withCString { FipsBridgeStartWithIdentity($0) }
        guard rc == 0 else {
            lastError = "The mesh endpoint could not bind (code \(rc))."
            log.error("mesh start failed: rc=\(rc, privacy: .public)")
            return
        }

        // Provider role: hand the mesh the port the relay and Blossom already
        // share, so a peer that dials this npub gets the same HTTP server a
        // browser on this machine would get.
        let exportRC = FipsBridgeExport(UInt16(relayPort))
        if exportRC != 0 {
            lastError = "The mesh is up but the relay port was not offered (code \(exportRC))."
        }

        refresh()
        startPolling()
        log.notice("mesh started: npub=\(self.status.npub, privacy: .public) address=\(self.status.address, privacy: .public) exported=\(self.status.exportedPorts.map(String.init).joined(separator: ","), privacy: .public)")
    }

    private func stop() {
        stopPolling()
        FipsBridgeStop()
        status = .stopped
        log.notice("mesh stopped")
    }

    /// The persisted network identity, generated once on first use.
    private func meshNsec() -> String {
        if let existing = CredentialStore.getMeshNsec(), !existing.isEmpty {
            return existing
        }
        guard let raw = FipsBridgeGenerateNsec() else { return "" }
        defer { FipsBridgeFreeString(raw) }
        let nsec = String(cString: raw)
        guard !nsec.isEmpty, CredentialStore.storeMeshNsec(nsec) else { return "" }
        return nsec
    }

    // MARK: - Status

    private func startPolling() {
        stopPolling()
        // Polled, not pushed: a callback from a Rust thread would need a
        // @convention(c) trampoline for one serialise a second.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() {
        guard let raw = FipsBridgeStatusJSON() else {
            status = .stopped
            return
        }
        defer { FipsBridgeFreeString(raw) }
        status = Self.parseStatus(String(cString: raw)) ?? .stopped
    }

    /// Split out from the FFI call so it can be exercised without the bridge.
    static func parseStatus(_ json: String) -> Status? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard root["running"] as? Bool == true else { return .stopped }

        let peers: [Peer] = (root["peers"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let npub = entry["npub"] as? String else { return nil }
            return Peer(
                npub: npub,
                alias: entry["alias"] as? String,
                connected: entry["connected"] as? Bool ?? false,
                address: entry["addr"] as? String,
                rttMs: entry["rtt_ms"] as? Int
            )
        }

        return Status(
            running: true,
            npub: root["npub"] as? String ?? "",
            address: root["address"] as? String ?? "",
            uptimeSeconds: root["uptime_s"] as? Int ?? 0,
            exportedPorts: (root["exported"] as? [Int]) ?? [],
            peers: peers
        )
    }
}
#endif
