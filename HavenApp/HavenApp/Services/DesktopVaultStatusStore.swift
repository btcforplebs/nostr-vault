#if os(iOS)
import Foundation

/// "Your desktop Vault": this phone's desktop Vault's status, read over the
/// mesh (`VaultStatusFromC`, docs/MESH_COPY_V2_CONTRACT.md §6.7) with the
/// copy token, only while the card is on screen. The last good answer and
/// when it came are kept, so the card can say how old it is when the
/// desktop is out of reach. Android twin: `DesktopVaultStatusStore.kt`.
@MainActor
final class DesktopVaultStatusStore: ObservableObject {
    static let shared = DesktopVaultStatusStore()

    struct Kept: Codable, Equatable {
        var peer: String
        var fetchedAt: Int64
        var json: Data
    }

    /// The last good answer from `peer`.
    @Published private(set) var status: VaultStatus?
    @Published private(set) var fetchedAt: Int64 = 0
    /// The last try failed (out of reach, not paired yet, an older desktop).
    @Published private(set) var lastError: String?
    @Published private(set) var checking = false

    private static let key = "desktopVaultStatus.kept"
    static let every: TimeInterval = 60
    private var peer: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let kept = try? JSONDecoder().decode(Kept.self, from: data) {
            peer = kept.peer
            status = VaultStatus.decode(kept.json)
            fetchedAt = kept.fetchedAt
        }
    }

    /// Shown for `peer`: drop what was kept for another desktop.
    func show(peer next: String) {
        guard next != peer else { return }
        peer = next
        status = nil
        fetchedAt = 0
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// One read now. Not while one is running.
    func refresh() async {
        guard let peer, !checking else { return }
        checking = true
        defer { checking = false }
        guard let base = await MeshCopyV2Service.base(peer) else {
            lastError = "unreachable"
            return
        }
        let raw: Data = await Task.detached(priority: .utility) {
            guard let pointer = peer.withCString({ p in base.withCString { b in
                VaultStatusFromC(UnsafeMutablePointer(mutating: p), UnsafeMutablePointer(mutating: b))
            } }) else { return Data() }
            defer { free(pointer) }
            return Data(String(cString: pointer).utf8)
        }.value
        guard peer == self.peer else { return }
        let answer = Self.answer(raw)
        if let (status, json) = answer.status {
            self.status = status
            fetchedAt = Int64(Date().timeIntervalSince1970)
            lastError = nil
            if let data = try? JSONEncoder().encode(Kept(peer: peer, fetchedAt: fetchedAt, json: json)) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        } else {
            lastError = answer.error ?? "bad_answer"
        }
    }

    /// The engine's {"status": …} or {"error": "<code>"}.
    static func answer(_ raw: Data) -> (status: (VaultStatus, Data)?, error: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return (nil, nil) }
        if let s = object["status"], let json = try? JSONSerialization.data(withJSONObject: s),
           let status = VaultStatus.decode(json) {
            return ((status, json), nil)
        }
        return (nil, object["error"] as? String)
    }
}
#endif
