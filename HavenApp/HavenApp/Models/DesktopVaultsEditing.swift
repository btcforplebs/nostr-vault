import Foundation

/// What the Desktop Vaults screens do to the Vault list (Desktop Vaults P4,
/// PLANS/NV_DESKTOP_VAULTS_PLAN.md §2.1, §2.5 rules 4 and 8, §2.7): add,
/// change an address, rename, drag, delete. Pure, so MediaLogicTests checks
/// it. Android twin: `relay/DesktopVaultsEditing.kt` (P7).
///
/// A deleted Vault leaves its addresses in `removed` (`removedKey`), so the
/// list's own followers (DesktopVaultsLogic.takingInSlot, which re-adds the
/// old slot's address, and followingDevices, which adds every paired Mac)
/// don't put it straight back. Adding the address again, or pairing that
/// device again, takes it off `removed`. This is how a Vault is turned off
/// once the old one-slot tab is gone (Tron N3 on #2499).
enum DesktopVaultsEditing {

    // MARK: Removed addresses

    /// The key `removed` holds for a web host or a mesh npub (the same
    /// spelling as a Vault id made from it).
    static func removedKey(host: String) -> String { DesktopVaultsLogic.id(httpsHost: host) }
    static func removedKey(meshNpub: String) -> String { DesktopVaultsLogic.id(meshNpub: meshNpub) }

    /// Every key a Vault's addresses have.
    static func removedKeys(of vault: DesktopVault) -> [String] {
        var keys: [String] = []
        if let npub = vault.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) { keys.append(removedKey(meshNpub: npub)) }
        if let host = vault.hostKey { keys.append(removedKey(host: host)) }
        return keys
    }

    /// The Vaults with every removed address taken off; a Vault left with no
    /// address goes. Order is kept and renumbered.
    static func applyingRemoved(_ vaults: [DesktopVault], removed: [String]) -> [DesktopVault] {
        guard !removed.isEmpty else { return vaults }
        let gone = Set(removed)
        var out = DesktopVaultsLogic.ordered(vaults)
        for i in out.indices {
            if let npub = out[i].meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)),
               gone.contains(removedKey(meshNpub: npub)) {
                out[i].meshNpub = nil
            }
            if let host = out[i].hostKey, gone.contains(removedKey(host: host)) { out[i].httpsURL = nil }
        }
        out.removeAll { $0.meshNpub == nil && $0.httpsURL == nil }
        return DesktopVaultsLogic.ordered(out)
    }

    // MARK: Rule 8: a bare IP address is never listed

    /// True when `url`'s host is a literal IPv4 or IPv6 address. Such a Vault
    /// still syncs over it, but none of its list switches may turn on: the
    /// address would be public (Tron S2; `isPrivateNetworkHost` only catches
    /// private ranges, not a WAN address).
    static func isIPHost(_ url: String) -> Bool {
        var host = DesktopVaultsLogic.base(url).lowercased()
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.hasPrefix("[") { return true }
        // More than one colon and no brackets: a bare IPv6 address.
        if host.filter({ $0 == ":" }).count > 1 { return true }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        while host.hasSuffix(".") { host.removeLast() }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }

    static let ipHostMessage = "Use a domain name; a bare IP address would be public."

    // MARK: Add

    enum AddRefusal: Error, Equatable {
        case noAddress
        case notWebAddress
        case notMeshAddress
        case ownAddress
        case hostTaken(DesktopVault)
        case meshTaken(DesktopVault)

        var message: String {
            switch self {
            case .noAddress: return "Pair it over the Mesh, type its web address, or both."
            case .notWebAddress: return "That isn't a web address. Type it like https://vault.example.com"
            case .notMeshAddress: return "That isn't a mesh address."
            case .ownAddress: return "That is this device's own address."
            case .hostTaken(let vault): return DesktopVaultsLists.hostTakenMessage(vault)
            case .meshTaken(let vault): return "That device is already your Vault \(vault.displayName)."
            }
        }
    }

    /// A new Vault from the Add sheet: a typed web address, a paired mesh
    /// npub, or both. A host or npub another Vault has is refused (rule 4).
    static func adding(name: String, httpsTyped: String, meshNpub: String?, kind: DesktopVaultKind,
                       to vaults: [DesktopVault], ownNpub: String?) -> Result<DesktopVault, AddRefusal> {
        let typed = httpsTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        var https: String?
        if !typed.isEmpty {
            guard let url = DesktopVaultsLogic.httpsURL(typed) else { return .failure(.notWebAddress) }
            if let other = DesktopVaultsLists.hostTaken(url, by: vaults) { return .failure(.hostTaken(other)) }
            https = url
        }
        var npub: String?
        if let raw = meshNpub?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let parsed = HomeVaultLogic.meshNpub(fromInput: raw) else { return .failure(.notMeshAddress) }
            if parsed == ownNpub { return .failure(.ownAddress) }
            if let other = vaults.first(where: { $0.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) == parsed }) {
                return .failure(.meshTaken(other))
            }
            npub = parsed
        }
        guard https != nil || npub != nil else { return .failure(.noAddress) }
        let id = npub.map(DesktopVaultsLogic.id(meshNpub:))
            ?? DesktopVaultsLogic.id(httpsHost: DesktopVaultsLists.hostKey(https!)!)
        let order = (vaults.map(\.order).max() ?? -1) + 1
        return .success(DesktopVault(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     kind: kind, meshNpub: npub, httpsURL: https, order: order))
    }

    /// The list with `vault` added at the end, and `removed` without its
    /// addresses: adding an address again undoes an earlier delete.
    static func inserting(_ vault: DesktopVault, into vaults: [DesktopVault],
                          removed: [String]) -> (vaults: [DesktopVault], removed: [String]) {
        let keys = Set(removedKeys(of: vault))
        var out = DesktopVaultsLogic.ordered(vaults)
        var added = vault
        added.order = out.count
        out.append(added)
        return (out, removed.filter { !keys.contains($0) })
    }

    // MARK: Change one Vault

    /// The Vault's web address changed (or cleared, `typed` empty). The old
    /// host goes on `removed`, so the old slot can't come back as a Vault of
    /// its own. Refused when another Vault has the new host, or when it
    /// would leave the Vault with no address.
    static func changingAddress(of id: String, to typed: String, in vaults: [DesktopVault],
                                removed: [String]) -> Result<(vaults: [DesktopVault], removed: [String]), AddRefusal> {
        guard let i = vaults.firstIndex(where: { $0.id == id }) else { return .failure(.noAddress) }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: String?
        if !trimmed.isEmpty {
            guard let url = DesktopVaultsLogic.httpsURL(trimmed) else { return .failure(.notWebAddress) }
            if let other = DesktopVaultsLists.hostTaken(url, by: vaults, except: id) { return .failure(.hostTaken(other)) }
            next = url
        }
        if next == nil, vaults[i].meshNpub == nil { return .failure(.noAddress) }
        var out = vaults
        var gone = removed
        if let old = out[i].hostKey, old != next.flatMap(DesktopVaultsLists.hostKey) {
            gone.append(removedKey(host: old))
        }
        if let host = next.flatMap(DesktopVaultsLists.hostKey) { gone.removeAll { $0 == removedKey(host: host) } }
        out[i].httpsURL = next
        return .success((out, unique(gone)))
    }

    static func renaming(_ id: String, to name: String, in vaults: [DesktopVault]) -> [DesktopVault] {
        vaults.map { vault in
            guard vault.id == id else { return vault }
            var renamed = vault
            renamed.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return renamed
        }
    }

    // MARK: Drag and delete

    /// The list after a drag (List.onMove's offsets), renumbered.
    static func moving(_ vaults: [DesktopVault], from source: IndexSet, to destination: Int) -> [DesktopVault] {
        var out = DesktopVaultsLogic.ordered(vaults)
        let moved = source.sorted().map { out[$0] }
        for index in source.sorted(by: >) { out.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        out.insert(contentsOf: moved, at: max(0, min(out.count, destination - before)))
        return out.enumerated().map { i, vault in
            var vault = vault
            vault.order = i
            return vault
        }
    }

    /// The list without `id`, and its addresses on `removed`.
    static func deleting(_ id: String, from vaults: [DesktopVault],
                         removed: [String]) -> (vaults: [DesktopVault], removed: [String]) {
        guard let vault = vaults.first(where: { $0.id == id }) else { return (vaults, removed) }
        let out = DesktopVaultsLogic.ordered(vaults.filter { $0.id != id })
        return (out, unique(removed + removedKeys(of: vault)))
    }

    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    // MARK: The old slot

    /// The one-slot `macRelayURL` while a Vault still has its address, else
    /// "". Code that still reads the slot (MAC_RELAY_URL, the old status
    /// file, search) reads this, so deleting that Vault turns it off too,
    /// while `macRelayURL` itself stays as it was for older builds (§3 step 5).
    static func slotInEffect(_ slot: String, vaults: [DesktopVault]) -> String {
        switch DesktopVaultsLogic.SlotAddress(slot) {
        case .none:
            return ""
        case .web(let host):
            return vaults.contains { $0.hostKey == host } ? slot : ""
        case .mesh(let npub):
            return vaults.contains { $0.meshNpub.flatMap(HomeVaultLogic.meshNpub(fromInput:)) == npub } ? slot : ""
        }
    }

    // MARK: Rows on Relays, DM inbox and Media Servers (§2.4)

    /// One Vault entry of a published list, shown read only as "From your
    /// Vault <name>".
    struct ListedEntry: Equatable, Identifiable {
        let vault: DesktopVault
        let url: String
        let mesh: Bool
        var id: String { "\(vault.id)|\(url)" }
    }

    /// The Vault entries of `tags`, in list order.
    static func listedEntries(_ tags: [[String]], in list: DesktopVaultList, vaults: [DesktopVault]) -> [ListedEntry] {
        tags.compactMap { tag in
            guard tag.count >= 2, let vault = DesktopVaultsLists.owner(of: tag, in: list, vaults: vaults) else { return nil }
            return ListedEntry(vault: vault, url: tag[1], mesh: DesktopVaultsLists.meshNpub(tag, in: list) != nil)
        }
    }

    /// `tags` split into the Vault entries (as published, in place) and the
    /// rest. A Relays save keeps the first part as it is: only a Vault's
    /// switch adds or removes its entries (§2.4, Tron M2).
    static func splitting(_ tags: [[String]], in list: DesktopVaultList,
                          vaults: [DesktopVault]) -> (vault: [[String]], other: [[String]]) {
        var vault: [[String]] = []
        var other: [[String]] = []
        for tag in tags {
            if tag.count >= 2, DesktopVaultsLists.owner(of: tag, in: list, vaults: vaults) != nil {
                vault.append(tag)
            } else {
                other.append(tag)
            }
        }
        return (vault, other)
    }
}
