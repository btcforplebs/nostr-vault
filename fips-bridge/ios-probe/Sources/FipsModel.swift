import Combine
import CryptoKit
import Foundation

/// Drives the Rust bridge and records what happened.
///
/// Note the shape of the boundary: every call here is control-plane and happens
/// at human timescales. The bytes never cross the FFI — they go over a loopback
/// TCP socket that `URLSession` opens on its own, which is the whole point of
/// the design. If this app can fetch through the proxy, so can AVURLAsset and
/// AsyncImage, because none of them can tell it isn't an ordinary origin.
@MainActor
final class FipsModel: ObservableObject {
    @Published var running = false
    @Published var npub = ""
    @Published var address = ""
    @Published var uptime = 0
    @Published var memoryMB: Double = 0

    @Published var peerNpub: String = UserDefaults.standard.string(forKey: "peerNpub") ?? ""
    @Published var loopbackPort: Int?
    @Published var busy = false
    @Published var log: [LogLine] = []

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let ok: Bool?
    }

    private var timer: Timer?

    func append(_ text: String, ok: Bool? = nil) {
        log.insert(LogLine(text: text, ok: ok), at: 0)
        if log.count > 60 { log.removeLast() }
    }

    func start() {
        guard !running else { return }
        busy = true
        append("starting embedded FIPS endpoint…")
        Task.detached(priority: .userInitiated) {
            // Blocking bind — must not run on the main actor.
            let rc = FipsBridgeStart()
            await MainActor.run {
                self.busy = false
                if rc == 0 {
                    self.append("endpoint bound", ok: true)
                    self.startPolling()
                } else {
                    self.append("FipsBridgeStart failed: \(rc)", ok: false)
                }
            }
        }
    }

    private func startPolling() {
        pollStatus()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStatus() }
        }
    }

    func pollStatus() {
        guard let pointer = FipsBridgeStatusJSON() else { return }
        let json = String(cString: pointer)
        FipsBridgeFreeString(pointer)

        memoryMB = Self.residentFootprintMB()

        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        running = object["running"] as? Bool ?? false
        npub = object["npub"] as? String ?? ""
        address = object["address"] as? String ?? ""
        uptime = object["uptime_s"] as? Int ?? 0
    }

    /// Open the loopback proxy pointed at the provider's npub.
    func connect() {
        let target = peerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            append("enter the provider npub first", ok: false)
            return
        }
        UserDefaults.standard.set(target, forKey: "peerNpub")
        busy = true
        append("opening loopback proxy → \(target.prefix(16))…")

        Task.detached(priority: .userInitiated) {
            let port = target.withCString { FipsBridgeIngress($0) }
            await MainActor.run {
                self.busy = false
                if port > 0 {
                    self.loopbackPort = Int(port)
                    self.append("proxy listening on 127.0.0.1:\(port)", ok: true)
                } else {
                    self.append("FipsBridgeIngress failed: \(port)", ok: false)
                }
            }
        }
    }

    /// Fetch through the loopback proxy with a stock URLSession — the actual
    /// product path, on real hardware.
    func fetch() async {
        guard let port = loopbackPort else {
            append("connect first", ok: false)
            return
        }
        busy = true
        defer { busy = false }

        let base = "http://127.0.0.1:\(port)"

        // 1. Full GET.
        guard let url = URL(string: "\(base)/blob") else { return }
        let started = Date()
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Date().timeIntervalSince(started)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let mib = Double(data.count) / 1024 / 1024

            append("GET \(status) · \(data.count) bytes", ok: status == 200)
            append(String(format: "  %.2f s · %.2f MiB/s", elapsed, mib / elapsed))
            append("  sha256 \(digest.prefix(16))…")
        } catch {
            append("GET failed: \(error.localizedDescription)", ok: false)
            return
        }

        // 2. Range request — proves the proxy is byte-transparent rather than
        //    re-serializing HTTP.
        do {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let contentRange = http?.value(forHTTPHeaderField: "Content-Range") ?? "—"
            append(
                "RANGE \(status) · \(data.count) bytes · \(contentRange)",
                ok: status == 206 && data.count == 1024
            )
        } catch {
            append("RANGE failed: \(error.localizedDescription)", ok: false)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        FipsBridgeStop()
        running = false
        loopbackPort = nil
        append("stopped")
    }

    /// Physical footprint, the number that matters for jetsam.
    static func residentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
