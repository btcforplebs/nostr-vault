import Foundation

/// What kind of desktop a Vault is. Shown only; it changes no path.
enum DesktopVaultKind: String, Codable, CaseIterable {
    case mac
    case linux
    case box
}

/// One of the owner's always-on desktop Vaults (PLANS/NV_DESKTOP_VAULTS_PLAN.md
/// §2.1). It replaces the one-slot `macRelayURL`. Which fields are set says
/// how it is reached:
/// - `meshNpub` only: over FIPS only;
/// - `httpsURL` only: over HTTPS only (public data and DMs, never drafts,
///   `/private`, `/chat`, settings, accounts or private files);
/// - both: both.
/// Which public lists name the Vault is never stored here: it is read from
/// the newest published lists (DesktopVaultsLists), so two devices can't
/// disagree about it. Android twin: `relay/DesktopVaults.kt`.
struct DesktopVault: Codable, Hashable, Identifiable {
    /// Stable and local. Made from the first address the Vault had
    /// (`DesktopVaultsLogic.id(...)`), so the same Vault made on two devices
    /// gets the same id.
    var id: String
    var name: String
    var kind: DesktopVaultKind
    /// Set: reachable over FIPS. The same npub as its MeshDevice.
    var meshNpub: String?
    /// Set: reachable over HTTPS, as `https://host[:port]`.
    var httpsURL: String?
    /// Position in the Desktop Vaults list; sets the order of Vault entries
    /// in the public lists (§2.5 rule 2).
    var order: Int

    init(id: String, name: String, kind: DesktopVaultKind = .mac, meshNpub: String? = nil,
         httpsURL: String? = nil, order: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.meshNpub = meshNpub
        self.httpsURL = httpsURL
        self.order = order
    }

    /// An unknown kind from a newer app reads as `.mac` rather than dropping
    /// the Vault; an unknown extra field is ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(DesktopVaultKind.self, forKey: .kind)) ?? .mac
        meshNpub = try c.decodeIfPresent(String.self, forKey: .meshNpub)
        httpsURL = try c.decodeIfPresent(String.self, forKey: .httpsURL)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }

    /// The host key of `httpsURL` (DesktopVaultsLists.hostKey), nil without one.
    var hostKey: String? { httpsURL.flatMap(DesktopVaultsLists.hostKey) }

    /// The name, or the address when none was given.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return hostKey ?? meshNpub.map { String($0.prefix(12)) + "…" } ?? "Desktop Vault"
    }
}

/// Stored Vaults that a newer app wrote with something this one can't read
/// are skipped one by one, like LossyMeshDevice.
struct LossyDesktopVault: Decodable {
    let vault: DesktopVault?

    init(from decoder: Decoder) throws {
        vault = try? DesktopVault(from: decoder)
    }
}
