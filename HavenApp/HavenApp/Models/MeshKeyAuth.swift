import Foundation

/// The mesh never uses the account key (Logen, 2026-11-06): the copy start
/// and Blossom over the mesh are signed by this device's own mesh key, and a
/// vault takes one only from a device in its paired set
/// (docs/MESH_COPY_V2_CONTRACT.md §2, §2.1). The tags here, and the set the
/// engine is given (SetMeshDevicesC), are built from the receiver's mesh
/// npub, so a token for one vault is refused by another.
enum MeshKeyAuth {
    /// A mesh 24242 lives at most this long (§2.1: five minutes ahead).
    static let blossomLifetime: TimeInterval = 5 * 60

    enum Verb: String {
        case upload, get, delete
    }

    /// The kind 27235 for POST <base>/copy/v2/start, signed by B's mesh key:
    /// `u`, `method`, and `p` = A's own mesh npub. No `device` tag: A binds
    /// the token to the signer.
    static func copyStartTags(base: URL, receiver: String) -> [[String]]? {
        let receiver = receiver.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = MeshCopyV2.startURL(base: base), !receiver.isEmpty else { return nil }
        return [["u", u], ["method", "POST"], ["p", receiver]]
    }

    /// A kind 24242 for one verb over the mesh: one `t`, an `x` for each
    /// blob, a `p` for each receiving vault, and an expiration no more than
    /// five minutes ahead. Nil without a blob or a receiver: the vault
    /// refuses both.
    static func blossomTags(verb: Verb, sha256s: [String], receivers: [String], now: Date = Date(),
                            lifetime: TimeInterval = blossomLifetime, size: Int? = nil) -> [[String]]? {
        let blobs = unique(sha256s.map { $0.lowercased() })
        let named = unique(receivers)
        guard !blobs.isEmpty, !named.isEmpty else { return nil }
        var tags = [["t", verb.rawValue]]
        tags += blobs.map { ["x", $0] }
        if let size { tags.append(["size", String(size)]) }
        tags += named.map { ["p", $0] }
        let ahead = min(max(lifetime, 1), blossomLifetime)
        tags.append(["expiration", String(Int64(now.timeIntervalSince1970 + ahead))])
        return tags
    }

    /// The JSON for SetMeshDevicesC: this device's mesh npub and My Devices
    /// without it, each once, roles kept. Nil when this device has no mesh
    /// key yet: the engine then keeps the set it has (none at first, which
    /// accepts no device).
    static func deviceSet(selfNpub: String?, devices: [MeshDevice]) -> String? {
        let own = selfNpub?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !own.isEmpty else { return nil }
        var seen = Set<String>()
        var list: [[String: String]] = []
        for device in devices where device.npub != own && seen.insert(device.npub).inserted {
            list.append(["npub": device.npub, "role": device.role.rawValue])
        }
        let body: [String: Any] = ["self": own, "devices": list]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The vault turned the device form down (it has no paired set yet: an
    /// older build, or a box before havend passes the set). One retry with
    /// the owner's form, for as long as vaults accept it. TODO(mesh-key):
    /// remove with the owner form.
    static func retriesWithOwnerForm(status: Int) -> Bool {
        status == 401 || status == 403
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
