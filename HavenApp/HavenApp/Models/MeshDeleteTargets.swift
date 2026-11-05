import Foundation

/// A device of the owner's that Delete everywhere reaches over the FIPS mesh,
/// and what to call it if the file stays there.
struct MeshDeleteTarget: Equatable {
    var npub: String
    var name: String

    /// How it is listed in a delete report: never the ingress URL, which
    /// carries a token.
    var key: String { "fipsmesh://\(npub)/" }
}

/// Where Delete everywhere goes over the mesh, as Android's MeshDeleteTargets:
/// the home vault, the Mac and each linked phone in My Devices, never this
/// device itself (its copy is the local one) and never a browser vault (it
/// keeps notes, not files). "Delete from media servers" keeps these copies.
///
/// A `.fips` address is never sent a plain HTTP delete (the old iOS path): it
/// went through the ordinary session, put the `.fips` name in front of DNS and
/// could only fail, so the banner said "Still on npub….fips" for a copy it
/// never reached (RESEARCH NV_MIRROR_DELETE_ANDROID_VS_IOS #6).
enum MeshDeleteTargets {
    static func of(devices: [MeshDevice], ownNpub: String?, includeHomeVault: Bool) -> [MeshDeleteTarget] {
        guard includeHomeVault else { return [] }
        let order: [MeshDeviceRole] = [.homeVault, .mac, .phone]
        var seen = Set<String>()
        var out: [MeshDeleteTarget] = []
        for role in order {
            for device in devices where device.role == role {
                let npub = device.npub.lowercased()
                guard npub.hasPrefix("npub1"), npub != ownNpub?.lowercased(), seen.insert(npub).inserted else { continue }
                let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(MeshDeleteTarget(npub: npub, name: name.isEmpty ? defaultName(role) : name))
            }
        }
        return out
    }

    /// The same words Android uses: "Still on blossom.primal.net and your home vault".
    static func defaultName(_ role: MeshDeviceRole) -> String {
        switch role {
        case .mac: return "your home vault"
        case .phone: return "your other phone"
        default: return "the home vault"
        }
    }

    /// Gone only when the DELETE was taken (or found nothing) and a HEAD
    /// right after says 404. A device that does not list this one answers on
    /// its mesh door, which has no DELETE and says 404 to it: without the HEAD
    /// that read as deleted while the file stayed. A nil check is no answer,
    /// which proves nothing.
    static func gone(deleteStatus: Int, checkStatus: Int?) -> Bool {
        ((200...299).contains(deleteStatus) || deleteStatus == 404) && checkStatus == 404
    }

    /// One owner token for every mesh device, covering the DELETE and the HEAD
    /// after it. It names each device as `<npub>.fips` (which a vault takes as
    /// itself), so it is never a token without a server, and it only ever goes
    /// to the owner's own devices. Same tags as Android.
    static func authTags(sha256: String, targets: [MeshDeleteTarget], now: Date = Date()) -> [[String]] {
        var tags = [["t", "delete"], ["t", "get"], ["x", sha256]]
        tags += targets.map { ["server", "\($0.npub).fips"] }
        tags.append(["expiration", String(Int64(now.timeIntervalSince1970 + BlossomDeleteAuth.lifetime))])
        return tags
    }

    /// A configured or listed server that is a mesh address (`fipsmesh://`,
    /// `<npub>.fips`): reached over the mesh above, never over HTTP.
    static func isMeshAddress(_ server: String) -> Bool {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("fipsmesh:") { return true }
        guard let host = URLComponents(string: trimmed)?.host else { return false }
        return host.hasSuffix(".fips")
    }
}
