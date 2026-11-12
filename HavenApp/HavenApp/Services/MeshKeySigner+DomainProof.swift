import Foundation

extension MeshKeySigner {
    /// The kind of a Mac's web-domain proof: ephemeral, never sent to a
    /// relay or put in any list (haven-go copyv2_device.go copyDomainProofKind).
    static let domainProofKind = 21240

    /// WEB_DOMAIN_PROOF for the engine (multi-Mac rules §3.3): `domain`
    /// signed with this Mac's own mesh key, as event JSON, so the owner's
    /// other devices learn over the mesh which domain is this Mac's. ""
    /// with no domain (a mesh-only Mac sends nothing) or no mesh key yet.
    /// The engine hands it only to own paired devices, device to device.
    static func domainProofJSON(domain: String) -> String {
        guard !domain.isEmpty,
              let event = sign(kind: domainProofKind, content: "", tags: [["domain", domain]]),
              let data = try? JSONEncoder().encode(event) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
